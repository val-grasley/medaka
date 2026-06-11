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

cat > "$WORK/src/show_debug.mdk" <<'EOF'
main : <IO> Unit
main = putStrLn (debug 42)
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

PROGRAMS="arith recur adt list closure maxalias show_debug eq deriving"

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

printf '\n%d ok, %d failing (of %d)\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
