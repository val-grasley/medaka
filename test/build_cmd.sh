#!/bin/sh
# medaka build — end-to-end native-binary build smoke + differential gate.
#
# Stage 3 sequence item 1 (prelude flip complete, Stage 3 #2a).  Drives the
# `medaka build` CLI subcommand on real user programs of increasing complexity,
# then diffs each native binary's stdout against the `medaka run` interpreter
# oracle (the bootstrap differential pattern — interpreter is the oracle).
#
# `medaka build` now passes the REAL `stdlib/core.mdk` prelude (Stage 3 #2a
# complete).  DCE drops unreachable `maximum`/`minimum`/`clamp`; the E20 unit-head
# fix closed the Arbitrary-impl gap.  The buildable surface includes:
#   - runtime externs (putStrLn/intToString/…), arithmetic, ADTs + match,
#     recursion, closures, tuples, records, arrays, multi-module data
#   - typeclass dispatch via the real prelude: debug/Debug, ==/Eq, compare/Ord,
#     map/Foldable, deriving (Eq, Debug)
# KNOWN GAP: `println` prints `0` instead of `()` as `main`'s auto-print because
# the emitter does not yet infer that the prelude function `println` returns LTUnit
# (it is emitted as a Medaka dict-dispatch call returning i64, typed LTInt by
# default; mdk_print_int(0) is called instead of mdk_print_unit). Item 2b sweep.
#
# NATIVE AUTO-PRINT.  The native runtime auto-prints `main`'s Unit as a trailing
# "()\n" that the interpreter oracle does NOT emit (same convention as
# bootstrap_lex.sh / diff_selfhost_llvm_modules.sh).  We append "()" to the oracle
# output before comparing.
#
# Usage:  sh test/build_cmd.sh
# Exit:   0 if every program builds and native stdout == oracle (+auto-print);
#         1 on any build/diff failure;
#         2 if the build is missing, no C compiler, or libgc is absent (opt-in,
#           same skip discipline as the LLVM gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
CC="${CC:-clang}"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

# libgc presence check (medaka build does its own detection; we just decide skip).
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then :
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then :
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then :
else echo "libgc (bdw-gc) not found — skipping (install bdw-gc)"; exit 2; fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- test programs (increasing complexity) ---------------------------------
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

# multi-module: entry imports an exported helper
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

# C5 (TYPECHECK-AUDIT): a name that is BOTH an imported standalone function AND an
# interface method.  box exports a standalone `toList`/`isEmpty` for a `Box` that has
# NO Foldable impl; entry uses them on a Box (-> standalone, routes RLocal) ALONGSIDE
# the genuine Foldable methods on List/Option.  The native RLocal arm must emit a
# direct call to the standalone; the genuine sites stay arg-tag dispatch.
mkdir -p "$WORK/src/svm"
cat > "$WORK/src/svm/box.mdk" <<'EOF'
public export data Box a = Box (List a)

export toList : Box a -> List a
toList (Box xs) = xs

export isEmpty : Box a -> Bool
isEmpty (Box xs) = match xs
  [] => True
  _ => False
EOF
cat > "$WORK/src/svm/entry.mdk" <<'EOF'
import box.{Box(..), toList, isEmpty}

b : Box Int
b = Box [1, 2]

main =
  println (toList b)
  println (isEmpty b)
  println (isEmpty [10, 20, 30])
  println (toList (Some 7))
EOF

# Real-prelude typeclass cases (Stage 3 #2a census):
# debug/Debug, ==/Eq, compare/Ord, map/Foldable, deriving (Eq, Debug).
# println: Stage 3 #2b — the Unit-return auto-print gap is fixed.  `println`'s
# inferred return type now resolves to LTUnit (callRetTy treats IO output externs
# as Unit), so `main`'s result auto-prints "()" instead of mdk_print_int(0).
cat > "$WORK/src/println.mdk" <<'EOF'
main : <IO> Unit
main = println "hello"
EOF

# println sequencing: two side-effecting println statements via let-_ binding,
# then a Unit result that auto-prints "()" (Stage 3 #2b).
cat > "$WORK/src/println_seq.mdk" <<'EOF'
main : <IO> Unit
main =
  let _ = println "one"
  println "two"
EOF

cat > "$WORK/src/show_debug.mdk" <<'EOF'
main : <IO> Unit
main = putStrLn (debug 42)
EOF

cat > "$WORK/src/eq.mdk" <<'EOF'
main : <IO> Unit
main = putStrLn (debug (42 == 42))
EOF

cat > "$WORK/src/ord.mdk" <<'EOF'
main : <IO> Unit
main = putStrLn (debug (compare 3 5))
EOF

cat > "$WORK/src/list_map.mdk" <<'EOF'
double : Int -> Int
double x = x * 2
main : <IO> Unit
main = putStrLn (debug (map double [1, 2, 3]))
EOF

cat > "$WORK/src/deriving.mdk" <<'EOF'
data Color = Red | Green | Blue deriving (Eq, Debug)
main : <IO> Unit
main = putStrLn (debug Red ++ " " ++ debug Blue ++ " " ++ debug (Red == Red))
EOF

PROGRAMS="arith recur adt list closure println println_seq show_debug eq ord list_map deriving"

pass=0; fail=0

check() { # $1=label  $2=mdk-path
  label="$1"; src="$2"; bin="$WORK/$label.bin"
  if ! "$MAIN" build "$src" -o "$bin" >"$WORK/$label.out" 2>"$WORK/$label.err"; then
    fail=$((fail+1)); printf 'FAIL %s (build)\n' "$label"
    sed 's/^/    /' "$WORK/$label.err" | head -5
    return
  fi
  native="$("$bin" 2>/dev/null)"
  oracle="$("$MAIN" run "$src" 2>/dev/null)"
  # native appends the auto-printed "()" line; oracle does not.
  expected="$oracle
()"
  if [ "$native" = "$expected" ]; then
    pass=$((pass+1)); printf 'ok   %s  (%s)\n' "$label" "$oracle"
  else
    fail=$((fail+1)); printf 'FAIL %s (diff)\n' "$label"
    printf '%s' "$expected" > "$WORK/exp.txt"
    printf '%s' "$native"   > "$WORK/got.txt"
    diff "$WORK/exp.txt" "$WORK/got.txt" | head -10 | sed 's/^/    /'
  fi
}

for p in $PROGRAMS; do
  check "$p" "$WORK/src/$p.mdk"
done
check "multimodule" "$WORK/src/mm/entry.mdk"
check "standalone_vs_method" "$WORK/src/svm/entry.mdk"

printf '\n%d ok, %d failing (of %d)\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
