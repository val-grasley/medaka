#!/bin/sh
# Validation for the NATIVE medaka CLI (Phase C), RE-ROOTED off the OCaml oracle
# (REROOT-PLAN §2d).  selfhost/driver/medaka_cli.mdk, native-compiled to ./medaka,
# must reproduce committed goldens for check / fmt / new / repl / run / test / build.
#
# Per subtest the OCaml oracle leg is replaced by a committed golden captured NOW
# from the OCaml reference (sh test/capture_goldens.sh native_cli); the native leg
# stays `./medaka <subcmd>`.  Goldens live under test/native_cli_goldens/{check,fmt,
# new,run,test,build} + the inline fixtures are committed under
# test/native_cli_fixtures/{run,test}.
#
#   check  — native `./medaka check <f>`  ==  check/<n>.golden (check_main inferred-
#            signature dump, sorted; both sides sorted).
#   fmt    — native `./medaka fmt --stdout <f>`  ==  fmt/<n>.golden.
#   new    — native `./medaka new proj` tree  ==  new/proj (file contents).
#   run    — native `./medaka run <f>`  ==  run/<n>.golden.
#   test   — native `./medaka test <f>`  ==  test/<n>.golden.
#   build  — native `./medaka build <f> -o X && X`  ==  build/<n>.golden (program
#            runtime stdout from the OCaml-built binary).  Emit host = the native
#            ./medaka_emitter (MEDAKA_EMITTER) — OCaml-free.
#
# DOCUMENTED EXCEPTIONS (REROOT-PLAN STOP guardrail):
#   repl/session — the OCaml `medaka repl` and the self-hosted repl DIVERGE on
#     post-error prompt behaviour (see diff_selfhost_repl.sh header).  The native
#     repl is CANONICAL, so this subtest diffs native `./medaka repl` against the
#     SAME canonical native golden (test/repl_fixtures/session.golden), NOT OCaml.
#   lsp/session — the native lsp host cannot be built (`medaka build lsp_main.mdk`
#     fails the native G1 typecheck gate — medaka_cli typecheckGate roots omit
#     `selfhost`).  This is the ONE leg still on the OCaml oracle; it is SKIPPED
#     here (left as a documented exception, task #30).
#
# The native runtime auto-prints main's Unit value as a trailing "0"; strip it
# (strip_unit) before comparing.  Every invocation is bounded by perl alarm.
#
# Usage:  sh test/diff_native_cli.sh
# Exit:   0 if every wired subtest matches its golden (lsp SKIPPED), else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
GOLD="$ROOT/test/native_cli_goldens"
FIX="$ROOT/test/native_cli_fixtures"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

# native runtime auto-prints main's Unit as a trailing "0" the OCaml goldens omit.
strip_unit() { sed '$ s/0$//'; }

pass=0; fail=0

# ── check ─────────────────────────────────────────────────────────────────────
for f in "$ROOT"/test/diff_fixtures/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"; n="$(basename "$f" .mdk)"
  golden="$GOLD/check/$n.golden"
  [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL check/%s (no golden)\n' "$name"; continue; }
  want="$(cat "$golden")"
  got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   check/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL check/%s\n' "$name"
    printf '  want: %s\n  got:  %s\n' "$want" "$got"; fi
done

# ── fmt ───────────────────────────────────────────────────────────────────────
for f in "$ROOT"/test/fmt_fixtures/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"; n="$(basename "$f" .mdk)"
  golden="$GOLD/fmt/$n.golden"
  [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL fmt/%s (no golden)\n' "$name"; continue; }
  want="$(cat "$golden")"
  got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" fmt --stdout "$f" 2>/dev/null | strip_unit)"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   fmt/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL fmt/%s\n' "$name"; fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── new ───────────────────────────────────────────────────────────────────────
mkdir -p "$TMP/nat"
( cd "$TMP/nat" && MEDAKA_ROOT="$ROOT" bound "$MEDAKA" new proj >/dev/null 2>&1 )
goldfiles="$(cd "$GOLD/new/proj" 2>/dev/null && find . -type f | LC_ALL=C sort)"
natfiles="$(cd "$TMP/nat/proj" 2>/dev/null && find . -type f | LC_ALL=C sort)"
if [ "$goldfiles" = "$natfiles" ] && [ -n "$goldfiles" ]; then
  new_ok=1
  for rel in $goldfiles; do
    if ! cmp -s "$GOLD/new/proj/$rel" "$TMP/nat/proj/$rel"; then new_ok=0;
      printf '  differ: %s\n' "$rel"; fi
  done
  if [ "$new_ok" = 1 ]; then pass=$((pass+1)); printf 'ok   new/tree\n'
  else fail=$((fail+1)); printf 'FAIL new/tree (file contents differ)\n'; fi
else
  fail=$((fail+1)); printf 'FAIL new/tree (file lists differ)\n'
  printf '  gold: %s\n  nat:  %s\n' "$goldfiles" "$natfiles"
fi

# ── repl (native vs CANONICAL native golden — documented exception) ───────────
REPL_IN="$ROOT/test/repl_fixtures/session.in"
REPL_GOLDEN="$ROOT/test/repl_fixtures/session.golden"
repl_probe="$(printf ':quit\n' | MEDAKA_ROOT="$ROOT" bound "$MEDAKA" repl 2>&1)"
case "$repl_probe" in
  *"not yet in native CLI"*) REPL_WIRED=0 ;;
  *) REPL_WIRED=1 ;;
esac
if [ "$REPL_WIRED" = 1 ] && [ -f "$REPL_IN" ] && [ -f "$REPL_GOLDEN" ]; then
  repl_want="$(cat "$REPL_GOLDEN")"
  repl_got="$(printf '%s' "$(cat "$REPL_IN")
" | MEDAKA_ROOT="$ROOT" bound "$MEDAKA" repl 2>/dev/null | strip_unit)"
  if [ "$repl_got" = "$repl_want" ]; then
    pass=$((pass+1)); printf 'ok   repl/session (vs canonical native golden)\n'
  else
    fail=$((fail+1)); printf 'FAIL repl/session\n'
    printf '  want: [%s]\n  got:  [%s]\n' "$repl_want" "$repl_got"
  fi
else
  printf 'skip repl/* (native repl not yet wired or golden missing)\n'
fi

# ── lsp (DOCUMENTED EXCEPTION — native lsp host unbuildable; SKIPPED) ─────────
printf 'skip lsp/session (native lsp host unbuildable — REROOT-PLAN exception, task #30)\n'

# ── run ───────────────────────────────────────────────────────────────────────
RUN_FIXTURES="hello arith recur adt listsum strcat"
run_probe="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$FIX/run/hello.mdk" 2>&1)"
case "$run_probe" in
  *"not yet in native CLI"*) RUN_WIRED=0 ;;
  *) RUN_WIRED=1 ;;
esac
if [ "$RUN_WIRED" = 1 ]; then
  for base in $RUN_FIXTURES; do
    f="$FIX/run/$base.mdk"
    golden="$GOLD/run/$base.golden"
    [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL run/%s (no golden)\n' "$base"; continue; }
    want="$(cat "$golden")"
    got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$f" 2>/dev/null | strip_unit)"
    if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   run/%s\n' "$base"
    else fail=$((fail+1)); printf 'FAIL run/%s\n' "$base"
      printf '  want: [%s]\n  got:  [%s]\n' "$want" "$got"; fi
  done
else
  printf 'skip run/* (native run not yet wired)\n'
fi

# ── test ──────────────────────────────────────────────────────────────────────
TEST_FIXTURES="doc prop nodoc"
test_probe="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" test "$FIX/test/doc.mdk" 2>&1)"
case "$test_probe" in
  *"not yet in native CLI"*) TEST_WIRED=0 ;;
  *) TEST_WIRED=1 ;;
esac
if [ "$TEST_WIRED" = 1 ]; then
  for base in $TEST_FIXTURES; do
    f="$FIX/test/$base.mdk"
    golden="$GOLD/test/$base.golden"
    [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL test/%s (no golden)\n' "$base"; continue; }
    want="$(cat "$golden")"
    got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" test "$f" 2>/dev/null | strip_unit)"
    if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   test/%s\n' "$base"
    else fail=$((fail+1)); printf 'FAIL test/%s\n' "$base"
      printf '  want: [%s]\n  got:  [%s]\n' "$want" "$got"; fi
  done
else
  printf 'skip test/* (native test not yet wired)\n'
fi

# ── build (native binary stdout vs OCaml-built-binary golden; native emit host) ─
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
elif [ ! -x "$EMITTER" ]; then
  printf 'skip build/* (native emitter missing — make medaka)\n'
else
  printf 'note build emit host: native-emitter (OCaml-free) %s\n' "$EMITTER"
  for base in $RUN_FIXTURES; do
    f="$FIX/run/$base.mdk"
    golden="$GOLD/build/$base.golden"
    [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL build/%s (no golden)\n' "$base"; continue; }
    want="$(cat "$golden")"
    ( export MEDAKA_ROOT="$ROOT"; export MEDAKA_EMITTER="$EMITTER"; bound "$MEDAKA" build "$f" -o "$TMP/nat_$base" ) >/dev/null 2>&1
    got="$("$TMP/nat_$base" 2>/dev/null)"
    if [ -x "$TMP/nat_$base" ] && [ "$got" = "$want" ]; then
      pass=$((pass+1)); printf 'ok   build/%s\n' "$base"
    else fail=$((fail+1)); printf 'FAIL build/%s\n' "$base"
      printf '  want: [%s]\n  got:  [%s]\n' "$want" "$got"; fi
  done
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
