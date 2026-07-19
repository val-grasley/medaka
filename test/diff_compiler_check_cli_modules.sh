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

# 10. THE S2 INVERSION (SHADOW-SEMANTICS row 14 / cell d8) — DEFINER shadow with an
#     IMPORTED interface+impl.  The CONSUMER defines the standalone `size : Int -> Int`
#     and IMPORTS the interface `Sizeable` + type `Box(..)` + its impl from `dprov`.
#
#     ⚠️ RE-PINNED 2026-07-14, ACCEPT(3,4) -> located REJECT.  This leg was added by
#     ebb8ee90 (P0-19 batch 2) to assert the OLD S2: "the impl universe is GLOBAL, so
#     `size (Box 3)` must DISPATCH to the imported `impl Sizeable Box`".  The inversion
#     abolishes the rule that leg encoded — a DEFINER shadow is now the standalone,
#     unconditionally, and the impl universe is never queried.  So `size (Box 3)` types
#     against the consumer's own `size : Int -> Int` and REJECTS `Type mismatch: Int vs
#     Box` at the call site, on check AND run AND build.  This is a DELIBERATE revert of
#     a two-day-old intentional fix, not a regression — see the d8 row in
#     test/diff_compiler_shadow_semantics.sh.
#
#     S6 still holds, but VACUOUSLY: where the interface and impl live cannot change the
#     outcome, because the outcome no longer depends on them.  The all-local cell d2
#     rejects identically, which is the point.
#
#     ⚠️ The IMPORTER-shadow leg immediately above (#9) is the Fork-1 control and MUST
#     still ACCEPT + dispatch (3,4): an `import` is a SIBLING scope, not an inner one,
#     so it does NOT shadow.  If #9 and #10 ever agree, the inversion has leaked.
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
dfn_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/dmain.mdk" 2>&1)"
dfn_code=$?
# The standalone WINS: `size (Box 3)` must be a LOCATED reject against `size : Int -> Int`.
case "$dfn_out" in
  *"dmain.mdk:7:10: Type mismatch: Int vs Box"*)
    if [ "$dfn_code" -ne 0 ]; then pass=$((pass+1)); printf 'ok   definer-shadow-xmod/check (S2 inversion: standalone wins, located reject at the call)\n'
    else fail=$((fail+1)); printf 'FAIL definer-shadow-xmod/check (diagnosed but exit 0)\n'; fi ;;
  *) fail=$((fail+1)); printf 'FAIL definer-shadow-xmod/check (want located "Int vs Box" at 7:10, got exit %d: [%s])\n' "$dfn_code" "$dfn_out" ;;
esac
# build AGREEMENT (S7): the same project must FAIL to build, and emit no binary.
if MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/dmain.mdk" -o "$TMP/dfn.bin" >/dev/null 2>&1 && [ -x "$TMP/dfn.bin" ]; then
  fail=$((fail+1)); printf 'FAIL definer-shadow-xmod/build (built a binary; the standalone-domain reject must stop it)\n'
else
  pass=$((pass+1)); printf 'ok   definer-shadow-xmod/build (S2 inversion: rejected, no binary — agrees with check)\n'
fi

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

# 12. IMPORTED-MODULE *RESOLVE* diagnostics (#41 — the RESOLVE-path analog of leg 11).
#     Leg 11 covers imported TYPE errors (routed through analyzeProject, which already
#     bucketed by file); RESOLVE errors take a DIFFERENT CLI path
#     (resolveModulesToHumane*) that applied a SINGLE `target` fallback to EVERY
#     module's errors, so an imported module's `Unbound variable` printed the ENTRY
#     file's path (and, for a >entry-length file, an entry line number that does not
#     exist).  The per-module path map (resolveModulesToHumaneByPath) must now
#     attribute the imported module's resolve error to ITS OWN file.
cat > "$TMP/reshelper.mdk" <<'EOF'
export rh : Int -> Int
rh x = x + missingName
EOF
cat > "$TMP/resuse.mdk" <<'EOF'
import reshelper.{rh}
main = println (rh 3)
EOF
res_chk="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/resuse.mdk" 2>&1)"
res_chk_code=$?
case "$res_chk" in
  *resuse.mdk:*"Unbound variable"*) fail=$((fail+1)); printf 'FAIL imported-resolve/attr (#41 regressed: imported error mislabeled as entry: [%s])\n' "$res_chk" ;;
  *reshelper.mdk:*:*:*"Unbound variable"*) if [ "$res_chk_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   imported-resolve/attr (#41: imported resolve error located at its OWN file)\n'
                  else fail=$((fail+1)); printf 'FAIL imported-resolve/attr (located but exit %d)\n' "$res_chk_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL imported-resolve/attr (imported resolve error not located: [%s])\n' "$res_chk" ;;
esac

# 13. ENTRY-PROJECT internal-extern trust (#42, POSITIVE).  A sibling module of the
#     entry, within the SAME `medaka.toml` project, legitimately calls an
#     internal-only kernel (`arrayGetUnsafe`).  Checking your OWN multi-module
#     project must NOT require `--allow-internal`: the entry project's own modules
#     are trusted exactly as stdlib is.  (Previously trusted ONLY stdlib, so this
#     flagged `internal-only primitive` unless the flag was passed.)  The trust
#     keys on the manifest — a `medaka.toml` marks this as a real project (a LOOSE
#     no-manifest file stays untrusted; that leg lives in
#     diff_compiler_internal_extern.sh).  Must ACCEPT (no internal-only error).
mkdir -p "$TMP/ownproj"
cat > "$TMP/ownproj/medaka.toml" <<'EOF'
name = "ownproj"
EOF
cat > "$TMP/ownproj/kern.mdk" <<'EOF'
export first : Array Int -> Int
first a = arrayGetUnsafe 0 a
EOF
cat > "$TMP/ownproj/kernuse.mdk" <<'EOF'
import kern.{first}
main = println (first (arrayFromList [1, 2, 3]))
EOF
kern_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/ownproj/kernuse.mdk" 2>&1)"
kern_code=$?
case "$kern_out" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL own-project-trust (#42 regressed: own sibling flagged internal-only: [%s])\n' "$kern_out" ;;
  *) if [ "$kern_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   own-project-trust (#42: entry-project sibling may use internal kernels)\n'
     else fail=$((fail+1)); printf 'FAIL own-project-trust (exit %d: [%s])\n' "$kern_code" "$kern_out"; fi ;;
esac

# 14. DECLARED-DEPENDENCY internal-extern trust (#42, SECURITY BOUNDARY / NEGATIVE).
#     The trust from leg 13 must NOT extend to a THIRD-PARTY dependency: a dep
#     declared in medaka.toml [dependencies] resolves to a root OUTSIDE the entry's
#     search roots, so its use of an internal-only kernel MUST still be REJECTED
#     (this is the whole point of the guard — an imported package cannot silently
#     reach for memory-unsafe primitives).  Rejected + attributed to the DEP's file.
mkdir -p "$TMP/depapp" "$TMP/depdep"
cat > "$TMP/depdep/medaka.toml" <<'EOF'
name = "depdep"
EOF
cat > "$TMP/depdep/k.mdk" <<'EOF'
export peek : Array Int -> Int
peek a = arrayGetUnsafe 0 a
EOF
cat > "$TMP/depapp/medaka.toml" <<'EOF'
name = "depapp"

[dependencies]
depdep = "../depdep"
EOF
cat > "$TMP/depapp/m.mdk" <<'EOF'
import depdep.k.{peek}
main = println (peek (arrayFromList [1, 2, 3]))
EOF
dep_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/depapp/m.mdk" 2>&1)"
dep_code=$?
case "$dep_out" in
  *k.mdk:*:*:*"internal-only primitive"*) if [ "$dep_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   dep-untrusted (#42 boundary: declared dep still rejected, located at dep file)\n'
                  else fail=$((fail+1)); printf 'FAIL dep-untrusted (rejected but exit %d)\n' "$dep_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL dep-untrusted (#42 boundary BROKEN: dep internal-extern not rejected: [%s])\n' "$dep_out" ;;
esac

# 15. #201 (letrec, MULTI-MODULE half).  A top-level `let rec` non-function binding
#     in an IMPORTED module was SILENTLY ACCEPTED — the flat single-file path runs
#     checkLetRecDecls but the multi-module body (checkModuleFullImpl) did not.  PR-A
#     hoists the pass into the module body, so the imported bad decl now rejects with
#     a LOCATED diagnostic (dep.mdk:L:C:) and exit 1.  The flat half is pinned by
#     test/run_check_agreement_fixtures/reject_toplevel_letrec_nonfunction.mdk.
cat > "$TMP/lrdep.mdk" <<'EOF'
export loop : Int
let rec loop = loop
EOF
cat > "$TMP/lruse.mdk" <<'EOF'
import lrdep.{loop}
main = println loop
EOF
lr_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/lruse.mdk" 2>&1)"
lr_code=$?
case "$lr_out" in
  *lrdep.mdk:*:*:*"is bound by 'let rec' but its right-hand side is not a function"*)
    if [ "$lr_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   letrec-xmod (#201: imported let-rec non-function located + rejected)\n'
    else fail=$((fail+1)); printf 'FAIL letrec-xmod (located but exit %d)\n' "$lr_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL letrec-xmod (#201 regressed: imported let-rec non-function not rejected: [%s])\n' "$lr_out" ;;
esac

# 16. #201 (effect-param, MULTI-MODULE half).  An atomic effect label given a
#     parameter in an IMPORTED module was SILENTLY ACCEPTED — the flat path runs
#     checkEffectParams, the multi-module body did not.  PR-A hoists the pass into
#     the module body, so the imported bad sig now rejects located + exit 1.  The
#     flat half is pinned by run_check_agreement_fixtures/reject_effect_param_atomic.
cat > "$TMP/effdep.mdk" <<'EOF'
effect Bar

export f : Int -> <Bar "x"> Int
f n = n
EOF
cat > "$TMP/effuse.mdk" <<'EOF'
import effdep.{f}
main = println (f 3)
EOF
eff_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/effuse.mdk" 2>&1)"
eff_code=$?
case "$eff_out" in
  *effdep.mdk:*:*:*"is atomic and takes no parameter"*)
    if [ "$eff_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   effect-param-xmod (#201: imported atomic-effect param located + rejected)\n'
    else fail=$((fail+1)); printf 'FAIL effect-param-xmod (located but exit %d)\n' "$eff_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL effect-param-xmod (#201 regressed: imported effect-param error not rejected: [%s])\n' "$eff_out" ;;
esac

# 17. CROSS-MODULE effect-domain population (#80 BREAK #3 guard / over-rejection).
#     Module A declares `effect MyEff Prefix`; module B uses `<MyEff "svc/*">` with a
#     VALID prefix parameter.  This MUST be ACCEPTED: PR-A populates effect domains
#     ONCE over the WHOLE import graph in the driver preamble (checkModulesPreamble /
#     elaborateModules) and stops resetState from re-seeding, so B sees A's declared
#     Prefix domain.  A naive per-module hoist of populateEffectDomains would wipe A's
#     domain before B, leaving only builtins → B would FALSELY reject `MyEff` as
#     atomic ("label 'MyEff' is atomic and takes no parameter").  So a spurious reject
#     here means the cross-module effect-domain population regressed.
cat > "$TMP/effprov.mdk" <<'EOF'
effect MyEff Prefix

export ping : Unit -> <MyEff "svc/*"> Int
ping _ = 0
EOF
cat > "$TMP/effok.mdk" <<'EOF'
import effprov.{ping}
main = println (ping ())
EOF
effok_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/effok.mdk" 2>&1)"
effok_code=$?
case "$effok_out" in
  *"is atomic and takes no parameter"*) fail=$((fail+1)); printf 'FAIL effect-xmod/accept (BREAK #3: cross-module effect domain not populated: [%s])\n' "$effok_out" ;;
  *) if [ "$effok_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   effect-xmod/accept (cross-module Prefix effect domain populated over the graph)\n'
     else fail=$((fail+1)); printf 'FAIL effect-xmod/accept (exit %d: [%s])\n' "$effok_code" "$effok_out"; fi ;;
esac

# 12. #674 CROSS-MODULE DUPLICATE PUBLIC CONSTRUCTOR.  Two modules each export a
#     ctor of the SAME NAME.  The check side (typecheck/exhaust, last-loaded-wins) and
#     the native mangler (per-unit, first-import-wins) used to DISAGREE on which one a
#     bare `Node`/`Box` binds — check accepted, run was right, the native build CRASHED
#     (E-NONEXHAUSTIVE-MATCH), and a bare `import` of the OTHER module wrongly rejected
#     a VALID program.  The fix: import-scope the check-side ctor tables + reject a
#     genuine cross-module ctor collision at resolve time.  Legs a–d below.
cat > "$TMP/x674a.mdk" <<'EOF'
public export data TA = Node Int
export ma : TA
ma = Node 111
EOF
cat > "$TMP/x674b.mdk" <<'EOF'
public export data TB = Node Int
export mb : TB
mb = Node 222
EOF
# 12a. AMBIGUOUS: importing BOTH `Node`-exporting modules and USING `Node` is a
#      hard resolve error (R-AMBIGUOUS-CTOR), exit 1 — NOT a silent accept.
cat > "$TMP/x674_amb.mdk" <<'EOF'
import x674b.{TB(..), mb}
import x674a.{TA(..), ma}
unA : TA -> Int
unA (Node x) = x
main = println (intToString (unA ma))
EOF
amb_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check --json "$TMP/x674_amb.mdk" 2>/dev/null)"
amb_code=$?
case "$amb_out" in
  *R-AMBIGUOUS-CTOR*) if [ "$amb_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   674a/ambiguous-ctor (cross-module dup ctor rejected, exit 1)\n'
                  else fail=$((fail+1)); printf 'FAIL 674a/ambiguous-ctor (flagged but exit %d)\n' "$amb_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL 674a/ambiguous-ctor (no R-AMBIGUOUS-CTOR: [%s])\n' "$amb_out" ;;
esac
# 12b. build AGREEMENT: the ambiguous program must NOT build a (crashing) binary —
#      check and build agree that it is rejected, so the S0 miscompile is gone.
MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/x674_amb.mdk" -o "$TMP/x674_amb.bin" >/dev/null 2>&1
amb_bcode=$?
if [ "$amb_bcode" -ne 0 ] && [ ! -x "$TMP/x674_amb.bin" ]; then
  pass=$((pass+1)); printf 'ok   674b/no-crash-binary (ambiguous ctor never builds an executable)\n'
else
  fail=$((fail+1)); printf 'FAIL 674b/no-crash-binary (build exit %d, binary present=%s)\n' "$amb_bcode" "$([ -x "$TMP/x674_amb.bin" ] && echo yes || echo no)"
fi
# 12c. BARE-IMPORT VALIDITY: a bare `import x674b` (binds NO names — impls only) must
#      NOT inject its `Node` and reject a valid program that uses only x674a's `Node`.
#      check ACCEPTS and build AGREES, running to `111`.
cat > "$TMP/x674_bare.mdk" <<'EOF'
import x674a.{TA(..), ma}
import x674b
unA : TA -> Int
unA (Node x) = x
main = println (intToString (unA ma))
EOF
bare_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/x674_bare.mdk" 2>/dev/null)"
bare_code=$?
case "$bare_out" in
  *"Type mismatch"*|*Ambiguous*) fail=$((fail+1)); printf 'FAIL 674c/bare-import-valid (bare import wrongly rejected: [%s])\n' "$bare_out" ;;
  *) if [ "$bare_code" -eq 0 ]; then
       if MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/x674_bare.mdk" -o "$TMP/x674_bare.bin" >/dev/null 2>&1 && [ "$("$TMP/x674_bare.bin" 2>/dev/null)" = "111" ]; then
         pass=$((pass+1)); printf 'ok   674c/bare-import-valid (bare import stays impls-only; check+build run to 111)\n'
       else fail=$((fail+1)); printf 'FAIL 674c/bare-import-valid (check clean but build/run wrong)\n'; fi
     else fail=$((fail+1)); printf 'FAIL 674c/bare-import-valid (exit %d: [%s])\n' "$bare_code" "$bare_out"; fi ;;
esac
# 12d. USE-SITE firing: importing BOTH `Node`-exporting modules but USING NEITHER's
#      `Node` stays LEGAL (the ambiguity check fires only on a genuine ambiguous use).
cat > "$TMP/x674_unused.mdk" <<'EOF'
import x674b.{TB(..), mb}
import x674a.{TA(..), ma}
main = println "hi"
EOF
unused_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/x674_unused.mdk" 2>/dev/null)"
unused_code=$?
case "$unused_out" in
  *Ambiguous*) fail=$((fail+1)); printf 'FAIL 674d/import-both-use-neither (false ambiguity on unused ctor: [%s])\n' "$unused_out" ;;
  *) if [ "$unused_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   674d/import-both-use-neither (unused dup ctor stays legal)\n'
     else fail=$((fail+1)); printf 'FAIL 674d/import-both-use-neither (exit %d: [%s])\n' "$unused_code" "$unused_out"; fi ;;
esac

# 13. #673 cross-module constrained-FUNCTION obligation on the located CHECK path.
#     Two guards, one root cause (instantiateVarTracked dropped a cross-module binding's
#     call obligation because per-module schemeObligationsRef has no entry for it):
#
#  13a. UNDER-rejection (#673 itself): a PRELUDE constrained fn (`println : Display a => …`)
#       applied to a 6-tuple (Display impls stop at arity 5) in an import-bearing program
#       MUST be rejected on `check` — it false-greened (exit 0, empty --json) while run/build
#       rejected via their separate dict net.  The fix reads core's OWN captured obligations
#       (coreSchemeObligationsRef) so the located path records the Display obligation.
cat > "$TMP/x673_reject.mdk" <<'EOF'
import helper.{double}
main = println (double 1, double 1, double 1, double 1, double 1, double 1)
EOF
x673r_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/x673_reject.mdk" 2>/dev/null)"
x673r_code=$?
case "$x673r_out" in
  *"No impl of Display for (Int, Int, Int, Int, Int, Int)"*)
    if [ "$x673r_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   673a/prelude-fn-obligation (cross-module println Display obligation enforced)\n'
    else fail=$((fail+1)); printf 'FAIL 673a/prelude-fn-obligation (rejected but exit %d)\n' "$x673r_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL 673a/prelude-fn-obligation (cross-module obligation dropped: [%s])\n' "$x673r_out" ;;
esac
#  13b. OVER-rejection guard (the #673-rework regression): two modules export a same-named
#       `bar` — foo's is `Display a =>`-constrained, baz's is UNCONSTRAINED — and the entry
#       uses BAZ's `bar` on a no-`Display` type.  This is VALID; `check` MUST accept it.  A
#       source-BLIND name lookup misattributes foo's Display constraint to baz's `bar` and
#       falsely rejects `No impl of Display for NoD`; the source-exact lookup (qualConstraintFor
#       resolves `bar`→baz via currentImportDefinersRef) must not.  Asserted on `check` ONLY:
#       run/build reject this shape via a SEPARATE, PRE-EXISTING emit-path same-name over-
#       rejection bug (present on main, independent of #673 and out of scope here).
cat > "$TMP/x673_foo.mdk" <<'EOF'
public export data FooT = FooT
export bar : Display a => a -> String
bar x = display x
EOF
cat > "$TMP/x673_baz.mdk" <<'EOF'
export bar : a -> a
bar x = x
EOF
cat > "$TMP/x673_collide.mdk" <<'EOF'
import x673_baz.{bar}
import x673_foo
public export data NoD = NoD
main =
  let _ = bar NoD
  println "ok"
EOF
x673c_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/x673_collide.mdk" 2>/dev/null)"
x673c_code=$?
case "$x673c_out" in
  *"No impl"*) fail=$((fail+1)); printf 'FAIL 673b/samename-no-overreject (misattributed foreign constraint: [%s])\n' "$x673c_out" ;;
  *) if [ "$x673c_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   673b/samename-no-overreject (baz unconstrained bar not tagged with foo Display)\n'
     else fail=$((fail+1)); printf 'FAIL 673b/samename-no-overreject (exit %d: [%s])\n' "$x673c_code" "$x673c_out"; fi ;;
esac

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
