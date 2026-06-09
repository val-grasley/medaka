#!/bin/sh
# medaka build — end-to-end native-binary build smoke + differential gate.
#
# Stage 3 sequence item 1.  Drives the `medaka build` CLI subcommand on a handful
# of real user programs of increasing complexity, then diffs each native binary's
# stdout against the `medaka run` interpreter oracle (the bootstrap differential
# pattern — interpreter is the oracle).
#
# `medaka build` shells the self-hosted LLVM emitter
# (selfhost/llvm_emit_modules_main.mdk) with an EMPTY prelude — the same subset
# every LLVM gate uses (the full stdlib/core.mdk prelude is not yet emittable; it
# hits the open max/min arg-tag-dispatch gap, EMITTER-GAPS.md residual).  So the
# test programs stay within that subset: runtime externs (putStrLn/intToString),
# primitive arithmetic, ADTs + match, recursion, closures, multi-module data.
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

PROGRAMS="arith recur adt list closure"

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

printf '\n%d ok, %d failing (of %d)\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
