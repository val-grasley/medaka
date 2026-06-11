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
#   deferred — native `./medaka build x` prints "not yet in native CLI", exit 1.
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
defmsg="$(bound "$MEDAKA" build x 2>&1 1>/dev/null)"
bound "$MEDAKA" build x >/dev/null 2>&1; defcode=$?
case "$defmsg" in
  *"not yet in native CLI"*)
    if [ "$defcode" = 1 ]; then pass=$((pass+1)); printf 'ok   deferred/build\n'
    else fail=$((fail+1)); printf 'FAIL deferred/build (exit %s != 1)\n' "$defcode"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL deferred/build (msg: %s)\n' "$defmsg" ;;
esac

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
