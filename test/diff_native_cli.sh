#!/bin/sh
# Differential validation for the NATIVE medaka CLI (Phase C Slice 0+1):
# selfhost/medaka_cli.mdk, native-compiled to ./medaka, must reproduce the OCaml
# reference for the check / fmt / new subcommands it wires.
#
#   check  — native `./medaka check <f>`  ==  OCaml `main.exe run check_main.mdk
#            <rt> <core> <f>`.  (The native CLI's check IS check.runCheck, the
#            same logic check_main.mdk drives; OCaml `main.exe check` prints a
#            different "OK — N bindings" surface and is NOT the oracle here.)
#   fmt    — native `./medaka fmt --stdout <f>`  ==  OCaml `main.exe fmt --stdout <f>`.
#   new    — native `./medaka new <name>` scaffolds the same file tree (contents)
#            as OCaml `main.exe new <name>`.
#   build  — native `./medaka build F -o X && X`  ==  OCaml `main.exe build F -o Y && Y`
#            over llvm_fixtures (the native CLI drives emit→clang with no OCaml in
#            its own logic; the emit step shells out to the emitter, hosted by
#            MEDAKA — set to the native ./medaka run path when available, else the
#            OCaml exe).  Both native binaries' stdout must be byte-identical.
#   run    — native `./medaka run F`  ==  OCaml `main.exe run F` over llvm_fixtures.
#
# The native runtime auto-prints main's Unit value as a trailing "0"; strip it
# (strip_unit) before comparing against the OCaml driver, which does not.
# Every native/OCaml invocation is bounded by `perl -e 'alarm N; exec @ARGV'`
# (macOS has no `timeout`).
#
# Usage:  sh test/diff_native_cli.sh
# Exit:   0 if every fixture matches + the deferred assertion holds, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
MEDAKA="$ROOT/medaka"
CHECK_MAIN="$ROOT/selfhost/check_main.mdk"
RT="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

[ -x "$MAIN" ]   || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build first: medaka build selfhost/medaka_cli.mdk -o ./medaka (missing $MEDAKA)"; exit 2; }

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

# Drop the native runtime's trailing Unit auto-print: a lone "0" appended to the
# last line of stdout (no preceding newline from the program's final putStr).
strip_unit() { sed '$ s/0$//'; }

pass=0; fail=0

# ── check: native runCheck == OCaml-interpreted check_main ──────────────────
for f in "$ROOT"/test/diff_fixtures/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  want="$(bound "$MAIN" run "$CHECK_MAIN" "$RT" "$CORE" "$f" 2>/dev/null | LC_ALL=C sort)"
  got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   check/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL check/%s\n' "$name"
    printf '  want: %s\n  got:  %s\n' "$want" "$got"; fi
done

# ── fmt: native fmt --stdout == OCaml fmt --stdout ──────────────────────────
for f in "$ROOT"/test/fmt_fixtures/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  want="$(bound "$MAIN" fmt --stdout "$f" 2>/dev/null)"
  got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" fmt --stdout "$f" 2>/dev/null | strip_unit)"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   fmt/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL fmt/%s\n' "$name"; fi
done

# ── new: scaffolded file tree (contents) identical ──────────────────────────
# Same project name under separate dirs, so the only legitimate difference
# (the name baked into medaka.toml / README) is eliminated.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/oc" "$TMP/nat"
( cd "$TMP/oc"  && bound "$MAIN" new proj >/dev/null 2>&1 )
( cd "$TMP/nat" && MEDAKA_ROOT="$ROOT" bound "$MEDAKA" new proj >/dev/null 2>&1 )
ocfiles="$(cd "$TMP/oc/proj" 2>/dev/null && find . -type f | LC_ALL=C sort)"
natfiles="$(cd "$TMP/nat/proj" 2>/dev/null && find . -type f | LC_ALL=C sort)"
if [ "$ocfiles" = "$natfiles" ] && [ -n "$ocfiles" ]; then
  new_ok=1
  for rel in $ocfiles; do
    if ! cmp -s "$TMP/oc/proj/$rel" "$TMP/nat/proj/$rel"; then new_ok=0;
      printf '  differ: %s\n' "$rel"; fi
  done
  if [ "$new_ok" = 1 ]; then pass=$((pass+1)); printf 'ok   new/tree\n'
  else fail=$((fail+1)); printf 'FAIL new/tree (file contents differ)\n'; fi
else
  fail=$((fail+1)); printf 'FAIL new/tree (file lists differ)\n'
  printf '  oc:  %s\n  nat: %s\n' "$ocfiles" "$natfiles"
fi

# ── deferred: build subcommand → "not yet" on stderr, exit 1 ────────────────
defmsg="$(bound "$MEDAKA" test x 2>&1 1>/dev/null)"
bound "$MEDAKA" test x >/dev/null 2>&1; defcode=$?
case "$defmsg" in
  *"not yet in native CLI"*)
    if [ "$defcode" = 1 ]; then pass=$((pass+1)); printf 'ok   deferred/test\n'
    else fail=$((fail+1)); printf 'FAIL deferred/test (exit %s != 1)\n' "$defcode"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL deferred/test (msg: %s)\n' "$defmsg" ;;
esac

# ── run: native ./medaka run F == OCaml main.exe run F ──────────────────────
# A handful of representative runnable fixtures.  The native CLI's `run` routes
# eval.mdk's load→typecheck→eval (eval_typed_modules_main path), forcing main;
# its captured output is NOT auto-print-suffixed (evalModulesOutput returns the
# string), so strip the trailing native-CLI Unit "0" only.
# ── inline IO fixtures (printed output, so the oracle is meaningful) ─────────
# Value-`main` llvm_fixtures auto-print only under the native runtime, not under
# `medaka run`; to compare run/build honestly we use programs whose `main` is an
# IO action emitting via putStrLn (identical surface on every path).
SRC="$TMP/src"; mkdir -p "$SRC"
cat > "$SRC/hello.mdk" <<'EOF'
main : <IO> Unit
main = putStrLn "hello, medaka"
EOF
cat > "$SRC/arith.mdk" <<'EOF'
main : <IO> Unit
main = putStrLn (intToString (2 + 3 * 4 - (10 / 3) + (17 % 5) + (0 - 7) / 2))
EOF
cat > "$SRC/recur.mdk" <<'EOF'
fact : Int -> Int
fact n = if n <= 1 then 1 else n * fact (n - 1)
main : <IO> Unit
main = putStrLn (intToString (fact 6))
EOF
cat > "$SRC/adt.mdk" <<'EOF'
data Shape = Circle Int | Rect Int Int
area : Shape -> Int
area s = match s
  Circle r => r * r * 3
  Rect w h => w * h
main : <IO> Unit
main = putStrLn (intToString (area (Circle 4) + area (Rect 3 5)))
EOF
cat > "$SRC/listsum.mdk" <<'EOF'
data IntList = Nil | Cons Int IntList
sumL : IntList -> Int
sumL xs = match xs
  Nil => 0
  Cons h t => h + sumL t
main : <IO> Unit
main = putStrLn (intToString (sumL (Cons 1 (Cons 2 (Cons 3 (Cons 4 Nil))))))
EOF
cat > "$SRC/strcat.mdk" <<'EOF'
main : <IO> Unit
main = putStrLn (stringConcat ["a", "b", stringConcat ["c", "d"]])
EOF
RUN_FIXTURES="hello arith recur adt listsum strcat"

# Is native `run` wired yet?  (Slice-2 lands build first, then run.)  Probe once;
# when deferred, skip run cases and host the build emit with the OCaml exe.
run_probe="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$SRC/hello.mdk" 2>&1)"
case "$run_probe" in
  *"not yet in native CLI"*) RUN_WIRED=0 ;;
  *) RUN_WIRED=1 ;;
esac

if [ "$RUN_WIRED" = 1 ]; then
  for base in $RUN_FIXTURES; do
    f="$SRC/$base.mdk"
    want="$(bound "$MAIN" run "$f" 2>/dev/null)"
    got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$f" 2>/dev/null | strip_unit)"
    if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   run/%s\n' "$base"
    else fail=$((fail+1)); printf 'FAIL run/%s\n' "$base"
      printf '  want: [%s]\n  got:  [%s]\n' "$want" "$got"; fi
  done
else
  printf 'skip run/* (native run not yet wired)\n'
fi

# ── build: native ./medaka build F == OCaml main.exe build F (binary stdout) ─
# The native CLI drives emit→clang with no OCaml in ITS logic.  The emit step
# shells out to the emitter; host it with the native ./medaka run path (MEDAKA),
# closing the OCaml-free loop once `run` is wired.  Compare both built binaries'
# stdout (the native runtime auto-print is identical on both, so no strip needed).
# Skip the whole build block if no clang / libgc (opt-in, like build_cmd.sh).
build_skip=0
command -v "${CC:-clang}" >/dev/null 2>&1 || build_skip=1
if [ "$build_skip" = 0 ]; then
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then :
  elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then :
  elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "${CC:-clang}" -x c - -lgc -o /dev/null 2>/dev/null; then :
  else build_skip=1; fi
fi
if [ "$build_skip" = 1 ]; then
  printf 'skip build/* (no clang or libgc)\n'
else
  BUILD_FIXTURES="$RUN_FIXTURES"
  if [ -n "${MEDAKA_EMITTER:-}" ] && [ -x "${MEDAKA_EMITTER}" ]; then
    EMIT_ENV="MEDAKA_EMITTER=$MEDAKA_EMITTER"; emit_label="native-emitter (OCaml-free)"
  else
    EMIT_ENV="MEDAKA=$MAIN"; emit_label="ocaml-emit (native CLI drives emit→clang)"
  fi
  printf 'note build emit host: %s\n' "$emit_label"
  for base in $BUILD_FIXTURES; do
    f="$SRC/$base.mdk"
    # OCaml-built binary (oracle).
    bound "$MAIN" build "$f" -o "$TMP/oc_$base" >/dev/null 2>&1
    want="$("$TMP/oc_$base" 2>/dev/null)"
    # Native-CLI-built binary; emit hosted by native ./medaka run (OCaml-free).
    ( export MEDAKA_ROOT="$ROOT"; eval "export $EMIT_ENV"; bound "$MEDAKA" build "$f" -o "$TMP/nat_$base" ) >/dev/null 2>&1
    got="$("$TMP/nat_$base" 2>/dev/null)"
    if [ -x "$TMP/nat_$base" ] && [ "$got" = "$want" ]; then
      pass=$((pass+1)); printf 'ok   build/%s\n' "$base"
    else fail=$((fail+1)); printf 'FAIL build/%s\n' "$base"
      printf '  want: [%s]\n  got:  [%s]\n' "$want" "$got"; fi
  done
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
