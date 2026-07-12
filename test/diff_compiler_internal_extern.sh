#!/bin/sh
# Internal-extern access gate: a module that is NOT part of the standard library
# may not reference the internal-only array-kernel externs (arrayGetUnsafe,
# arraySetUnsafe, arrayBlit, arrayFill, arraySortInPlaceBy) unless the compile
# passes `--allow-internal`.  The trust signal is the loader's owning-root
# (stdlib modules are always trusted) plus the `--allow-internal` opt-in for the
# entry project's own modules.
#
# Legs (all on the real ./medaka CLI; never rebuilds it — see the diff_native_cli
# stale-binary footgun):
#   1. check-reject:   user file using arrayGetUnsafe → InternalExternAccess, exit 1.
#   2. check-allow:    same file with --allow-internal → clean (exit 0).
#   3. run-allow:      `run --allow-internal` evaluates it (prints the value).
#   4. run-reject:     `run` (no flag) → InternalExternAccess, exit 1.
#   5. build-reject:   `build` (no flag) → rejected, no binary emitted.
#   6. build-allow:    `build --allow-internal` → succeeds, runs.
#   7. stdlib-trust:   a user program importing `array` (whose body uses the
#                      externs) resolves clean WITHOUT the flag — no false positive.
#   8. fallthrough-ok: a user program with guard fallthrough (desugar emits
#                      `__fallthrough__`) is NOT flagged.
#   9. self-check-rel: `medaka check` on a REAL stdlib file, by its RELATIVE
#                      path from the repo root (e.g. `stdlib/array.mdk`, no
#                      non-core imports ⇒ the single-module route), resolves
#                      clean WITHOUT `--allow-internal` — a check-usability
#                      papercut fix (was: the single-module CLI route ignored
#                      the already-computed owning-root trust list, AND that
#                      list's root comparison broke on a relative-path root).
#  10. self-check-abs: same file, by its ABSOLUTE path — also clean.
#
# Usage:  sh test/diff_compiler_internal_extern.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# A user file that references an internal-only extern directly.
cat > "$TMP/u.mdk" <<'EOF'
main = println (arrayGetUnsafe 0 (arrayFromList [1, 2, 3]))
EOF

# 1. check-reject: no flag → InternalExternAccess error + exit 1.
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/u.mdk" 2>&1)"
code=$?
case "$out" in
  *"internal-only primitive"*) if [ "$code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   check-reject (InternalExternAccess, exit 1)\n'
                  else fail=$((fail+1)); printf 'FAIL check-reject (flagged but exit %d)\n' "$code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL check-reject (not flagged: [%s])\n' "$out" ;;
esac

# 2. check-allow: --allow-internal → clean (exit 0, no internal-only diagnostic).
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check --allow-internal "$TMP/u.mdk" 2>&1)"
code=$?
case "$out" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL check-allow (still flagged: [%s])\n' "$out" ;;
  *) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   check-allow (suppressed, exit 0)\n'
     else fail=$((fail+1)); printf 'FAIL check-allow (exit %d: [%s])\n' "$code" "$out"; fi ;;
esac

# 3. run-allow: --allow-internal evaluates it (prints 1).
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run --allow-internal "$TMP/u.mdk" 2>&1)"
code=$?
case "$out" in
  1*) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   run-allow (prints 1)\n'
      else fail=$((fail+1)); printf 'FAIL run-allow (printed but exit %d)\n' "$code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL run-allow ([%s])\n' "$out" ;;
esac

# 4. run-reject: run (no flag) → InternalExternAccess + exit 1.
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/u.mdk" 2>&1)"
code=$?
case "$out" in
  *"internal-only primitive"*) if [ "$code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   run-reject (InternalExternAccess, exit 1)\n'
                  else fail=$((fail+1)); printf 'FAIL run-reject (flagged but exit %d)\n' "$code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL run-reject (not flagged: [%s])\n' "$out" ;;
esac

# 5. build-reject: build (no flag) → rejected, no binary emitted.
rm -f "$TMP/u.out"
MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$ROOT/medaka_emitter" bound "$MEDAKA" build "$TMP/u.mdk" -o "$TMP/u.out" >/dev/null 2>&1
code=$?
if [ "$code" -ne 0 ] && [ ! -x "$TMP/u.out" ]; then
  pass=$((pass+1)); printf 'ok   build-reject (no binary, exit %d)\n' "$code"
else
  fail=$((fail+1)); printf 'FAIL build-reject (exit %d, binary present=%s)\n' "$code" "$([ -x "$TMP/u.out" ] && echo yes || echo no)"
fi

# 6. build-allow: build --allow-internal → succeeds, runs and prints 1.
rm -f "$TMP/u.out"
MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$ROOT/medaka_emitter" bound "$MEDAKA" build --allow-internal "$TMP/u.mdk" -o "$TMP/u.out" >/dev/null 2>&1
code=$?
if [ "$code" -eq 0 ] && [ -x "$TMP/u.out" ]; then
  rout="$("$TMP/u.out" 2>&1)"
  case "$rout" in
    1*) pass=$((pass+1)); printf 'ok   build-allow (binary runs, prints 1)\n' ;;
    *) fail=$((fail+1)); printf 'FAIL build-allow (binary ran: [%s])\n' "$rout" ;;
  esac
else
  fail=$((fail+1)); printf 'FAIL build-allow (exit %d, binary present=%s)\n' "$code" "$([ -x "$TMP/u.out" ] && echo yes || echo no)"
fi

# 7. stdlib-trust: a user file importing `array` (whose body uses the internal
#    externs) resolves clean WITHOUT --allow-internal — array.mdk is stdlib-owned
#    so it is always trusted; only the USER module is restricted.
cat > "$TMP/usearr.mdk" <<'EOF'
import array

main = println (arrayLength (arrayFromList [1, 2, 3]))
EOF
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/usearr.mdk" 2>&1)"
code=$?
case "$out" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL stdlib-trust (false positive on array.mdk: [%s])\n' "$out" ;;
  3*) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   stdlib-trust (array import resolves clean)\n'
      else fail=$((fail+1)); printf 'FAIL stdlib-trust (printed but exit %d)\n' "$code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL stdlib-trust ([%s])\n' "$out" ;;
esac

# 8. fallthrough-ok: a program with guard fallthrough (desugar emits the
#    compiler-generated `__fallthrough__` name) must NOT be flagged — it is
#    deliberately excluded from the internal-extern set.
cat > "$TMP/guard.mdk" <<'EOF'
classify : Int -> String
classify n
  | n > 0 = "pos"
  | n < 0 = "neg"
  | otherwise = "zero"

main = println (classify 5)
EOF
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/guard.mdk" 2>&1)"
code=$?
case "$out" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL fallthrough-ok (false positive on __fallthrough__: [%s])\n' "$out" ;;
  pos*) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   fallthrough-ok (guard fallthrough not flagged)\n'
        else fail=$((fail+1)); printf 'FAIL fallthrough-ok (printed but exit %d)\n' "$code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL fallthrough-ok ([%s])\n' "$out" ;;
esac

# 9. self-check-rel: `medaka check stdlib/array.mdk` (relative path, run with
#    cwd=$ROOT) — a genuine stdlib file that itself calls arrayGetUnsafe —
#    must resolve clean with NO flag.
out="$(cd "$ROOT" && MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check stdlib/array.mdk 2>&1)"
code=$?
case "$out" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL self-check-rel (false positive on stdlib/array.mdk: [%s])\n' "$out" ;;
  *) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   self-check-rel (stdlib/array.mdk clean, relative path, no flag)\n'
     else fail=$((fail+1)); printf 'FAIL self-check-rel (exit %d: [%s])\n' "$code" "$out"; fi ;;
esac

# 10. self-check-abs: same file, absolute path — also clean with no flag.
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$ROOT/stdlib/array.mdk" 2>&1)"
code=$?
case "$out" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL self-check-abs (false positive on stdlib/array.mdk: [%s])\n' "$out" ;;
  *) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   self-check-abs (stdlib/array.mdk clean, absolute path, no flag)\n'
     else fail=$((fail+1)); printf 'FAIL self-check-abs (exit %d: [%s])\n' "$code" "$out"; fi ;;
esac

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
