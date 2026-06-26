#!/bin/sh
# test/diff_compiler_effect_param.sh
#
# CLI-LEVEL differential gate for capability-effects v2 Stage 2a's PARAMETERIZED
# effect surface syntax.  This is the guard the unit-test suite never provided:
# test/test_typecheck.ml's `assert_type` parses via a RAW `Parser.program
# Lexer.token` call, bypassing the indentation-aware lexer pipeline the real CLI
# uses — so a CLI-only parse regression in this syntax would pass the unit tests
# and ship.  This gate exercises the syntax THROUGH BOTH real `check` front-ends:
#
#   * the OCaml reference CLI       (_build/default/bin/main.exe check)
#   * the native self-host CLI      (./medaka check)
#
# and against the OCaml-free native single-file host (test/bin/check_main, the
# same host diff_compiler_check.sh uses) cross-checked to the FROZEN-NATIVE
# === TYPES === golden baked into test/diff_fixtures/effect_param.golden.
#
# OCaml-free (LIB-REMOVAL-DESIGN §6 Stage A): the OCaml reference-CLI leg is
# removed; the gate exercises the syntax through the native CLI + native host,
# diffed against the committed (frozen-native) golden TYPES.
#
# Stage-2a forms covered by test/diff_fixtures/effect_param.mdk:
#   effect Net Prefix      — domain-carrying effect decl (Prefix refinement)
#   internal effect Mut    — non-public effect decl
#   effect Stdout          — plain (domainless) effect decl
#   <Net "a.com/foo">      — effect-row atom with a Prefix-pattern argument
#
# Prereqs: `make medaka` (native CLI + medaka_emitter) and
#          `FORCE=1 sh test/build_oracles.sh` (test/bin/check_main).
#
# Usage:  sh test/diff_compiler_effect_param.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/test/diff_fixtures/effect_param.mdk"
GOLD="$ROOT/test/diff_fixtures/effect_param.golden"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
NATIVE="$ROOT/medaka"
HOST="$ROOT/test/bin/check_main"

[ -f "$FIX" ]    || { echo "missing fixture $FIX"; exit 2; }
[ -f "$GOLD" ]   || { echo "missing golden $GOLD"; exit 2; }
[ -x "$NATIVE" ] || { echo "build native first: make medaka (missing $NATIVE)"; exit 2; }
[ -x "$HOST" ]   || { echo "build oracles first: FORCE=1 sh test/build_oracles.sh (missing $HOST)"; exit 2; }

strip_unit() { sed '$ s/0$//; $ s/()$//'; }
has_parse_err() { grep -qiE 'parse error|type error|unbound|unknown' ; }

pass=0; fail=0
note() { printf '%s %s\n' "$1" "$2"; }

# 1. Native self-host CLI must ACCEPT the syntax (no parse/type error in output).
#    (native `check` streams diagnostics and may exit 0 even on error, so we
#    assert on the text, not the exit code — and require the parameterized rows.)
nat_out="$(MEDAKA_ROOT="$ROOT" "$NATIVE" check "$FIX" 2>&1)"
if ! printf '%s' "$nat_out" | has_parse_err; then
  pass=$((pass+1)); note ok   "native-cli/check accepts effect-param syntax"
else
  fail=$((fail+1)); note FAIL "native-cli/check emitted an error: $(printf '%s' "$nat_out" | grep -iE 'parse|type|unbound|unknown' | head -1)"
fi

# 2. Native CLI must SURFACE the Prefix-parameterized row in the inferred sigs.
if printf '%s' "$nat_out" | grep -qF 'fetch : String -> <Net "a.com/foo"> String' \
   && printf '%s' "$nat_out" | grep -qF 'netGet : String -> <Net "a.com/foo"> String'; then
  pass=$((pass+1)); note ok   'native-cli/check infers <Net "a.com/foo"> rows'
else
  fail=$((fail+1)); note FAIL 'native-cli/check did not infer the <Net ...> rows'
fi

# 3. Native single-file host TYPES == committed (frozen-native) golden TYPES.
#    The host is the OCaml-free native front-end; the golden was captured from it
#    while OCaml was the trusted oracle (now frozen).  Byte-identical (sorted) ⇒
#    the host parses AND infers the parameterized-effect syntax as committed.
self="$("$HOST" "$RT" "$CORE" "$FIX" 2>/dev/null | strip_unit | LC_ALL=C sort)"
want="$(sed -n '/=== TYPES ===/,/=== EVAL ===/p' "$GOLD" | sed '1d;$d' | LC_ALL=C sort)"
if [ "$self" = "$want" ]; then
  pass=$((pass+1)); note ok   "native-host TYPES == committed golden (frozen-native)"
else
  fail=$((fail+1)); note FAIL "native-host TYPES != committed golden"
  _w="$(mktemp)"; _s="$(mktemp)"
  printf '%s\n' "$want" > "$_w"; printf '%s\n' "$self" > "$_s"
  diff "$_w" "$_s" | head -12 | sed 's/^/  /'; rm -f "$_w" "$_s"
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
