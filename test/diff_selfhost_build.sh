#!/bin/sh
# diff_selfhost_build.sh — differential gate for the SELF-HOSTED `medaka build`
# (Stage 4 Phase B.11).  Mirrors test/build_cmd.sh, but the binary under test is
# produced by the self-hosted build driver (selfhost/build_main.mdk, which shells
# out to the Medaka-hosted LLVM emitter + clang) rather than the OCaml
# lib/build_cmd.ml CLI.
#
# For each program (reusing build_cmd.sh's program set) it:
#   1. builds the native binary via the SELFHOST driver:
#        MEDAKA=<exe> MEDAKA_ROOT=<root> medaka run selfhost/build_main.mdk <prog> -o <bin>
#   2. builds the native binary via the OCaml CLI:  medaka build <prog> -o <bin2>
#   3. runs both binaries and the interpreter oracle (medaka run <prog>)
#   4. asserts  selfhost-binary stdout == OCaml-binary stdout == oracle + "()".
# The selfhost driver and the OCaml driver invoke the SAME emitter + clang
# command, so the two binaries must be behaviourally identical.
#
# NATIVE AUTO-PRINT: the native runtime auto-prints main's Unit as a trailing
# "()\n" the interpreter oracle omits; we append "()" to the oracle before diff
# (same convention as build_cmd.sh / diff_selfhost_llvm_modules.sh).
#
# Usage:  sh test/diff_selfhost_build.sh
# Exit:   0 if every program's selfhost binary == OCaml binary == oracle+autoprint;
#         1 on any build/diff failure;
#         2 if the build is missing, no C compiler, or libgc is absent (opt-in
#           skip, same discipline as the other LLVM gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
CC="${CC:-clang}"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then :
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then :
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then :
else echo "libgc (bdw-gc) not found — skipping (install bdw-gc)"; exit 2; fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/src"

cat > "$WORK/src/arith.mdk" <<'EOF'
main : <IO> Unit
main = putStrLn (intToString (2 + 3 * 4 - (10 / 3) + (17 % 5) + (0 - 7) / 2))
EOF

cat > "$WORK/src/recur.mdk" <<'EOF'
fact : Int -> Int
fact n = if n <= 1 then 1 else n * fact (n - 1)
main : <IO> Unit
main = putStrLn (intToString (fact 5))
EOF

cat > "$WORK/src/adt.mdk" <<'EOF'
data Shape = Circle Int | Rect Int Int
area : Shape -> Int
area s = match s
  Circle r => r * r * 3
  Rect w h => w * h
main : <IO> Unit
main = putStrLn (intToString (area (Circle 4) + area (Rect 3 5)))
EOF

cat > "$WORK/src/list.mdk" <<'EOF'
data IntList = Nil | Cons Int IntList
sumL : IntList -> Int
sumL xs = match xs
  Nil => 0
  Cons h t => h + sumL t
main : <IO> Unit
main = putStrLn (intToString (sumL (Cons 1 (Cons 2 (Cons 3 (Cons 4 Nil))))))
EOF

cat > "$WORK/src/closure.mdk" <<'EOF'
applyTwice : (Int -> Int) -> Int -> Int
applyTwice f x = f (f x)
main : <IO> Unit
main = putStrLn (intToString (applyTwice (x => x + 10) 5))
EOF

# gap #50 — interface method (max/min) used as a first-class value through a
# generic `Ord a`: point-free alias (callMax = max), the min analog, and a method
# passed to an Ord-constrained HOF.  All three lowered to garbage pre-fix.
cat > "$WORK/src/maxalias.mdk" <<'EOF'
callMax : Ord a => a -> a -> a
callMax = max
callMin : Ord a => a -> a -> a
callMin = min
applyOp : Ord a => (a -> a -> a) -> a -> a -> a
applyOp f x y = f x y
main : <IO> Unit
main =
  putStrLn (intToString (callMax 3 7))
  putStrLn (callMax "a" "z")
  putStrLn (intToString (callMin 3 7))
  putStrLn (intToString (applyOp max 4 9))
EOF

# maximum/minimum over a PRIMITIVE Ord receiver (Int + String).  The prelude
# helpers `maximum = fold step None` (where step calls `max m x`) are point-free,
# `=>`-constrained, and their under-applied method spine sits UNDER the `where`
# CLetGroup — the define came out arity-(dicts-only) while the call site supplied
# the value arg too, so the binary SIGSEGV'd under clang -O1+ (closed by
# etaSaturateMethodBody looking through CLet/CLetGroup to the tail).
cat > "$WORK/src/maxprim.mdk" <<'EOF'
main : <IO> Unit
main =
  putStrLn (debug (maximum [3, 7, 1]))
  putStrLn (debug (minimum [3, 7, 1]))
  putStrLn (debug (maximum ["a", "z", "m"]))
EOF

# clamp/compose (#12) — a point-free `=>`-constrained binding whose body is a
# CLOSURE VALUE: `clamp lo hi = min hi >> max lo` desugars compose `>>` to a CLam
# `\x -> max lo (min hi x)`.  dict-passing gives the clause `[$dict, lo, hi]`
# (arity 3) but the call site `clamp 0 10 7` passes `$dict + 3 value args`
# (arity 4) — the closure was RETURNED unapplied and the extra arg dropped,
# garbage out (SIGSEGV at -O2).  methodBodyDeficit is 0 (the body is a CLam value,
# not an under-applied method spine), so the signature-arity deficit + CLam-tail
# gate catches it (3rd wrapper shape of the eta-saturation family).
cat > "$WORK/src/clampc.mdk" <<'EOF'
clamp : Ord a => a -> a -> a -> a
clamp lo hi = min hi >> max lo
main : <IO> Unit
main =
  putStrLn (intToString (clamp 0 10 7))
  putStrLn (intToString (clamp 0 10 (0 - 5)))
  putStrLn (intToString (clamp 0 10 15))
  putStrLn (clamp "c" "p" "z")
EOF

# #55: point-free two-constraint (Foldable t, Num a) => fns.  sum/product are
# `fold (+) 0` / `fold (*) 1`: their `Num a` constraint var monomorphizes to Int
# (the literal seed), so the generalized scheme keeps ONLY `Foldable t` (1 dict)
# while the signature lists 2.  The define must be sized off the INFERRED arity (1
# dict + container) to match the call site; sizing off the sig (2) over-allocated a
# dict param → the container arg landed in an unpassed register → SIGSEGV at -O2.
cat > "$WORK/src/sum_twocstr.mdk" <<'EOF'
sumOf : (Foldable t, Num a) => t a -> a
sumOf = fold (+) 0
main : <IO> Unit
main =
  putStrLn (intToString (sum [1, 2, 3]))
  putStrLn (intToString (product [2, 3, 4]))
  putStrLn (intToString (sumOf [10, 20, 30]))
EOF

# G7: foldMap default body threads a method-level Monoid dict (`empty`) into the
# shared default define.  Covers BOTH monoids over the SAME container define (List
# container → List monoid AND String monoid) and a different container (Option).
# G9 regression (PRE-FLIP-GAPS §G9): the prelude `sum`/`product` seed via
# `fromInt 0`/`fromInt 1` (point-ful) so the accumulator type-directs to the
# element type, not pinned Int.  At Float, `fold (+) (fromInt 0)` was the blocker:
# the bare arithmetic SECTION `(+)`/`(*)` desugars to `\_a _b => _a OP _b`, whose
# untyped params defaulted LTInt -> integer add/mul on a boxed Float pointer
# (garbage / SIGSEGV / empty output).  The fix seeds an arith-section lambda's
# params LTNum so the body routes through @mdk_num_* (low-bit Int-vs-Float
# discriminator), correct for BOTH.  Exercises sum/product at Float AND Int.
cat > "$WORK/src/sumprod_float.mdk" <<'EOF'
main : <IO> Unit
main =
  putStrLn (debug (sum [1.0, 2.0, 3.0]))
  putStrLn (debug (product [2.0, 3.0]))
  putStrLn (debug (sum [1, 2, 3]))
  putStrLn (debug (product [2, 3, 4]))
EOF

cat > "$WORK/src/foldmap.mdk" <<'EOF'
main : <IO> Unit
main =
  putStrLn (debug (foldMap (x => [x, x]) [1, 2, 3]))
  putStrLn (foldMap (x => x) ["a", "b", "c"])
  putStrLn (debug (foldMap (x => [x]) (Some 42)))
EOF

# multi-module
mkdir -p "$WORK/src/mm"
cat > "$WORK/src/mm/helper.mdk" <<'EOF'
export double : Int -> Int
double x = x * 2
EOF
cat > "$WORK/src/mm/entry.mdk" <<'EOF'
import helper.{double}
main : <IO> Unit
main = putStrLn (intToString (double 21))
EOF

# L1 regression (TYPECHECK-AUDIT §L1): two modules each export a same-named
# top-level fn `f`, but module a's is `Num a => a -> a` (CONSTRAINED: 1 leading
# dict param) and module b's is `Int -> Int` (UNCONSTRAINED: no dict param).
# Both reached from main via distinct wrappers.  The pre-mangling joint dict-pass
# keyed arity by BARE NAME `f`, so a's constraint would force a spurious dict
# param onto b's `f` → b's call site under-applies → un-run partial closure →
# silent wrong/empty output (the Phase-134 class).  Universal per-module mangling
# (332ef41) renames them to `a__f`/`b__f` BEFORE elaborateModules dict-passes, so
# the bare-name collision is impossible by construction.  Correct output: viaA 10
# = 10+10 = 20, viaB 10 = 10+1 = 11 → "20 11".
mkdir -p "$WORK/src/l1"
cat > "$WORK/src/l1/a.mdk" <<'EOF'
export
f : Num a => a -> a
f x = x + x
export
viaA : Int -> Int
viaA n = f n
EOF
cat > "$WORK/src/l1/b.mdk" <<'EOF'
export
f : Int -> Int
f x = x + 1
export
viaB : Int -> Int
viaB n = f n
EOF
cat > "$WORK/src/l1/entry.mdk" <<'EOF'
import a.{viaA}
import b.{viaB}
main : <IO> Unit
main = putStrLn (intToString (viaA 10) ++ " " ++ intToString (viaB 10))
EOF

# nested (subfolder) module resolution: a DOTTED import `sub.helper` resolves to
# the nested file <root>/sub/helper.mdk (loader.mdk fileOfModuleId/moduleIdOfPath
# dot↔slash).  The nested module also imports a FLAT sibling (sib) at the entry
# root AND a stdlib module (list), confirming the loader roots compose and that a
# dotted module ID survives per-module name mangling into a valid LLVM symbol.
mkdir -p "$WORK/src/nested/sub"
cat > "$WORK/src/nested/sib.mdk" <<'EOF'
export bang : String -> String
bang s = stringConcat [s, "!!"]
EOF
cat > "$WORK/src/nested/sub/helper.mdk" <<'EOF'
import sib.{bang}
import list.{range, head}
export greet : String -> String
greet name =
  let n = match head (range 5 9)
    Some x => x
    None => 0
  bang (stringConcat ["Hi ", name, " first=", intToString n])
EOF
cat > "$WORK/src/nested/main.mdk" <<'EOF'
import sub.helper.{greet}
main : <IO> Unit
main = putStrLn (greet "there")
EOF

cat > "$WORK/src/show_debug.mdk" <<'EOF'
main : <IO> Unit
main = putStrLn (debug 42)
EOF

# G3 regression (PRE-FLIP-GAPS §G3): `Num a =>`-polymorphic arithmetic must
# tag-dispatch +/* at the operand's RUNTIME numeric type.  Before the fix the
# emitter hardwired the Int primitive for a type-var operand → at Float `+` gave
# garbage (silent wrong answer) and `*` SIGSEGV'd; Int was accidentally correct.
# The fix seeds such params/return LTNum and routes them through @mdk_num_*
# (low-bit Int-vs-boxed-Float discriminator).  Exercises + and * at Float AND Int.
cat > "$WORK/src/numpoly.mdk" <<'EOF'
double : Num a => a -> a
double x = x + x
square : Num a => a -> a
square x = x * x
main : <IO> Unit
main =
  putStrLn (debug (double 2.5))
  putStrLn (debug (square 2.5))
  putStrLn (debug (double 2))
  putStrLn (debug (square 3))
EOF

cat > "$WORK/src/eq.mdk" <<'EOF'
main : <IO> Unit
main = putStrLn (debug (42 == 42))
EOF

cat > "$WORK/src/deriving.mdk" <<'EOF'
data Color = Red | Green | Blue deriving (Eq, Debug)
main : <IO> Unit
main = putStrLn (debug Red ++ " " ++ debug Blue ++ " " ++ debug (Red == Red))
EOF

# Native #54/#21 residual: the Map interface-impl bodies (Eq/Ord/Debug/Display)
# delegate to `eq`/`compare`/`debug`/`display` of `toList m : List (k, v)`, whose
# nested per-element dispatch needs the impl's `requires` (Eq/Debug/… k, … v) dicts
# threaded into the synthesized element-dict cell.  Before the fix the cell's inner
# fields were 0 (null) → SIGSEGV; this fixture exercises all four impls.
cat > "$WORK/src/map_impl.mdk" <<'EOF'
import map.{Map, fromList}
main : <IO> Unit
main =
  let a = fromList [(1, "x"), (2, "y")] : Map Int String
  let b = fromList [(2, "y"), (1, "x")] : Map Int String
  let c = fromList [(1, "x")] : Map Int String
  putStrLn (debug (a == b))
  putStrLn (debug (a == c))
  putStrLn (debug a)
  putStrLn (display a)
  putStrLn (debug (compare c a))
EOF

# G4 regression (PRE-FLIP-GAPS §G4): a USER `data Box a` impl
# `impl Eq (Box a) requires Eq a` whose body's inner `x == y` is over the impl's
# abstract `requires`-constrained element.  Before the fix the operator route
# stayed RNone (abstract operand never grounds to a head tycon) → the shallow
# structural builtin (`mdk_value_eq` / pointer-eq) → SIGSEGV at the base/list case
# and a silent-wrong-answer (False) when nested.  The fix routes the operator RDict
# the impl's threaded element dict (resolveBinopSite consulting activeDictVarOf) so
# the inner compare dispatches through it; the #21 companion fix makes
# argImplDictRoutesFor search the FULL impl table (not the suffix from the matched
# outer entry) so the element dict cell carries its own nested element dict instead
# of a flat 1-word cell.  Exercises base (Box Int), list-field (Box [Int]), two-level
# nested (Box (Box Int)) AND a heterogeneous nested user wrapper (Box (Wrap Int)) —
# the case the suffix-table bug specifically dropped.
cat > "$WORK/src/g4_box_eq.mdk" <<'EOF'
data Box a = Box a
impl Eq (Box a) requires Eq a where
  eq (Box x) (Box y) = x == y
data Wrap a = Wrap a
impl Eq (Wrap a) requires Eq a where
  eq (Wrap x) (Wrap y) = x == y
main : <IO> Unit
main =
  putStrLn (debug (eq (Box 1) (Box 1)))
  putStrLn (debug (eq (Box [1, 2, 3]) (Box [1, 2, 3])))
  putStrLn (debug (eq (Box (Box 1)) (Box (Box 1))))
  putStrLn (debug (eq (Box (Wrap 1)) (Box (Wrap 1))))
  putStrLn (debug (eq (Box [1, 2, 3]) (Box [1, 2, 4])))
EOF

# Native Gap C (parametric default-method dict-synthesis, 2026-06-12): relational
# OPERATORS (`< <= > >=` → the Ord `lt`/`lte`/`gt`/`gte` DEFAULTS) and the by-name
# `lt`/`gte`, plus `max`/`min`/`maximum`/`minimum`, over a PARAMETRIC Ord head
# (built-in tuple, `List a`, AND a user `data Box a` with `impl Ord (Box a) requires
# Ord a`).  The Ord default reduces to the inner `compare`, whose parametric impl
# carries element `requires` dicts.  Before the fix typecheck's stampBinopRoute /
# resolveArgStamp BACKED OFF to RNone, which the backend lowered as a raw pointer
# `icmp` (silently WRONG result) on the operator path and a SIGSEGV on the by-name
# `lt` path; `maximum`/`minimum` (RDict dispatch chain) SIGSEGV'd too.  The fix keys
# the element dicts off the inner `compare`, eta-prepends matching dict params to
# `@mdk_default_<op>_<tag>`, and threads them into `@mdk_impl_<tag>_compare`.  Both
# the RKey path (direct `<`/`max`) AND the RDict path (`maximum`/`minimum`'s fold)
# load the element dicts.  Concrete Ord (Int/String) stays byte-identical.
cat > "$WORK/src/ord_parametric.mdk" <<'EOF'
data Box a = Box a
impl Eq (Box a) requires Eq a where
  eq (Box x) (Box y) = x == y
impl Ord (Box a) requires Ord a where
  compare (Box x) (Box y) = compare x y
main : <IO> Unit
main =
  putStrLn (debug ((1, 2) < (3, 4)))
  putStrLn (debug ((1, 2) >= (3, 4)))
  putStrLn (debug ((1, 5) > (1, 2)))
  putStrLn (debug (lt (1, 2) (3, 4)))
  putStrLn (debug (gte (1, 2) (3, 4)))
  putStrLn (debug (([1, 2] : List Int) < [1, 3]))
  putStrLn (debug (([1] : List Int) < [1, 2]))
  putStrLn (debug (Box 1 < Box 2))
  putStrLn (debug (Box 5 < Box 2))
  putStrLn (debug (lt (Box 1) (Box 9)))
  putStrLn (debug (max (1, 2) (3, 4)))
  putStrLn (debug (min (3, 4) (1, 2)))
  putStrLn (debug (maximum [(1, 2), (3, 1), (2, 9)]))
  putStrLn (debug (minimum [(3, 1), (1, 2), (2, 9)]))
  putStrLn (debug (1 < 2))
  putStrLn (debug ("abc" < "abd"))
EOF

PROGRAMS="arith recur adt list closure maxalias maxprim clampc sum_twocstr sumprod_float numpoly show_debug eq deriving map_impl g4_box_eq foldmap ord_parametric"

pass=0; fail=0

check() { # $1=label  $2=mdk-path
  label="$1"; src="$2"
  sbin="$WORK/$label.sb.bin"; obin="$WORK/$label.oc.bin"
  # 1. selfhost build
  if ! MEDAKA="$MAIN" MEDAKA_ROOT="$ROOT" CC="$CC" \
       "$MAIN" run "$ROOT/selfhost/build_main.mdk" "$src" -o "$sbin" \
       >"$WORK/$label.sb.out" 2>"$WORK/$label.sb.err"; then
    fail=$((fail+1)); printf 'FAIL %s (selfhost build)\n' "$label"
    sed 's/^/    /' "$WORK/$label.sb.err" | head -6
    return
  fi
  # 2. OCaml build
  if ! "$MAIN" build "$src" -o "$obin" >"$WORK/$label.oc.out" 2>"$WORK/$label.oc.err"; then
    fail=$((fail+1)); printf 'FAIL %s (ocaml build)\n' "$label"
    sed 's/^/    /' "$WORK/$label.oc.err" | head -6
    return
  fi
  # 3. run both + oracle
  sb="$("$sbin" 2>/dev/null)"
  oc="$("$obin" 2>/dev/null)"
  oracle="$("$MAIN" run "$src" 2>/dev/null)"
  expected="$oracle
()"
  if [ "$sb" = "$expected" ] && [ "$oc" = "$expected" ] && [ "$sb" = "$oc" ]; then
    pass=$((pass+1)); printf 'ok   %s  (%s)\n' "$label" "$oracle"
  else
    fail=$((fail+1)); printf 'FAIL %s (diff)\n' "$label"
    printf '  selfhost: %s\n' "$(printf '%s' "$sb" | tr '\n' '|')"
    printf '  ocaml   : %s\n' "$(printf '%s' "$oc" | tr '\n' '|')"
    printf '  expected: %s\n' "$(printf '%s' "$expected" | tr '\n' '|')"
  fi
}

for p in $PROGRAMS; do
  check "$p" "$WORK/src/$p.mdk"
done
check "multimodule" "$WORK/src/mm/entry.mdk"
check "l1_twomod" "$WORK/src/l1/entry.mdk"
check "nested_subfolder" "$WORK/src/nested/main.mdk"

printf '\n%d ok, %d failing (of %d)\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
