#!/bin/sh
# test/diff_selfhost_effect_param.sh
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
# same host diff_selfhost_check.sh uses) cross-checked to the OCaml `gen_golden`
# === TYPES === oracle baked into test/diff_fixtures/effect_param.golden.
#
# Stage-2a forms covered by test/diff_fixtures/effect_param.mdk:
#   effect Net Prefix      — domain-carrying effect decl (Prefix refinement)
#   internal effect Mut    — non-public effect decl
#   effect Stdout          — plain (domainless) effect decl
#   <Net "a.com/foo">      — effect-row atom with a Prefix-pattern argument
#
# Prereqs: `make medaka` (native CLI + medaka_emitter) and
#          `FORCE=1 sh test/build_oracles.sh` (test/bin/check_main),
#          and `dune build --root .` (OCaml main.exe).
#
# Usage:  sh test/diff_selfhost_effect_param.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/test/diff_fixtures/effect_param.mdk"
GOLD="$ROOT/test/diff_fixtures/effect_param.golden"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
OCAML="$ROOT/_build/default/bin/main.exe"
NATIVE="$ROOT/medaka"
HOST="$ROOT/test/bin/check_main"

[ -f "$FIX" ]    || { echo "missing fixture $FIX"; exit 2; }
[ -f "$GOLD" ]   || { echo "missing golden $GOLD (gen via dev/gen_golden.exe)"; exit 2; }
[ -x "$OCAML" ]  || { echo "build OCaml CLI first: dune build --root . (missing $OCAML)"; exit 2; }
[ -x "$NATIVE" ] || { echo "build native first: make medaka (missing $NATIVE)"; exit 2; }
[ -x "$HOST" ]   || { echo "build oracles first: FORCE=1 sh test/build_oracles.sh (missing $HOST)"; exit 2; }

strip_unit() { sed '$ s/0$//; $ s/()$//'; }
has_parse_err() { grep -qiE 'parse error|type error|unbound|unknown' ; }

pass=0; fail=0
note() { printf '%s %s\n' "$1" "$2"; }

# 1. OCaml reference CLI must ACCEPT the syntax (exit 0, "OK", no parse error).
oc_out="$("$OCAML" check "$FIX" 2>&1)"; oc_rc=$?
if [ "$oc_rc" -eq 0 ] && ! printf '%s' "$oc_out" | has_parse_err; then
  pass=$((pass+1)); note ok   "ocaml-cli/check accepts effect-param syntax"
else
  fail=$((fail+1)); note FAIL "ocaml-cli/check (rc=$oc_rc): $oc_out"
fi

# 2. Native self-host CLI must ACCEPT the syntax (no parse/type error in output).
#    (native `check` streams diagnostics and may exit 0 even on error, so we
#    assert on the text, not the exit code — and require the parameterized rows.)
nat_out="$(MEDAKA_ROOT="$ROOT" "$NATIVE" check "$FIX" 2>&1)"
if ! printf '%s' "$nat_out" | has_parse_err; then
  pass=$((pass+1)); note ok   "native-cli/check accepts effect-param syntax"
else
  fail=$((fail+1)); note FAIL "native-cli/check emitted an error: $(printf '%s' "$nat_out" | grep -iE 'parse|type|unbound|unknown' | head -1)"
fi

# 3. Native CLI must SURFACE the Prefix-parameterized row in the inferred sigs.
if printf '%s' "$nat_out" | grep -qF 'fetch : String -> <Net "a.com/foo"> String' \
   && printf '%s' "$nat_out" | grep -qF 'netGet : String -> <Net "a.com/foo"> String'; then
  pass=$((pass+1)); note ok   'native-cli/check infers <Net "a.com/foo"> rows'
else
  fail=$((fail+1)); note FAIL 'native-cli/check did not infer the <Net ...> rows'
fi

# 4. DIFFERENTIAL: native single-file host TYPES == OCaml gen_golden TYPES.
#    The committed golden is the OCaml `Typecheck.check_program` oracle; the host
#    is the OCaml-free native front-end.  Byte-identical (sorted) ⇒ the two
#    backends agree on parsing AND inferring the parameterized-effect syntax.
self="$("$HOST" "$RT" "$CORE" "$FIX" 2>/dev/null | strip_unit | LC_ALL=C sort)"
want="$(sed -n '/=== TYPES ===/,/=== EVAL ===/p' "$GOLD" | sed '1d;$d' | LC_ALL=C sort)"
if [ "$self" = "$want" ]; then
  pass=$((pass+1)); note ok   "native-host TYPES == OCaml oracle (differential)"
else
  fail=$((fail+1)); note FAIL "native-host TYPES != OCaml oracle"
  diff <(printf '%s' "$want") <(printf '%s' "$self") | head -12 | sed 's/^/  /'
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
