#!/bin/sh
# test/effect_set_domain.sh
#
# WS-3 NATIVE-ONLY gate for the Set refinement domain (set-shaped authority).
# The OCaml oracle is FROZEN and does NOT parse `<Foo {"a","b"}>` (this is a
# native-canonical enhancement, exactly like WS-1b's parameter compare), so this
# gate exercises the native `./medaka check` ALONE — no differential oracle.
#
# Covers:
#   P4   parse-error -> accept : `<Foo {"a","b"}>` now parses + typechecks
#   ACC  ⊆ accept             : body's row ⊆ declared bound -> accept
#   REJ  ⊄ reject             : body's row ⊄ declared bound -> TYPE ERROR
#   CAP  cardinality-cap      : union > setCardCap (16) saturates to ⊤ (<Foo>)
#
# Prereq: `make medaka` (native CLI).  Usage: sh test/effect_set_domain.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/medaka"
FIX="$ROOT/test/effect_set_fixtures"
export MEDAKA_ROOT="$ROOT"
[ -x "$M" ] || { echo "build native first: make medaka (missing $M)"; exit 2; }

pass=0; fail=0
run() { perl -e 'alarm 60; exec @ARGV' -- "$M" check "$1" 2>&1; }

# expect ACCEPT: no "TYPE ERROR" / "parse error" line
expect_ok() {
  out="$(run "$1")"
  if echo "$out" | grep -qiE 'TYPE ERROR|parse error'; then
    echo "FAIL $2 (expected accept):"; echo "$out" | grep -iE 'error' | head -2; fail=$((fail+1))
  else echo "ok   $2"; pass=$((pass+1)); fi
}
# expect REJECT: must contain "TYPE ERROR" and the expected performs-row text
expect_reject() {
  out="$(run "$1")"
  if echo "$out" | grep -q "$3"; then
    echo "ok   $2"; pass=$((pass+1))
  else echo "FAIL $2 (expected reject matching '$3'):"; echo "$out" | grep -iE 'error' | head -2; fail=$((fail+1)); fi
}

expect_ok     "$FIX/set_p4_parse_accept.mdk"      "P4  parse-accept"
expect_ok     "$FIX/set_subset_accept.mdk"        "ACC subset-accept"
expect_reject "$FIX/set_subset_reject.mdk"        "REJ subset-reject" 'performs <Foo {"a", "b"}>'
expect_ok     "$FIX/set_cap_saturate.mdk"         "CAP saturate-accept (top<=top)"
expect_reject "$FIX/set_cap_saturate_ctrl.mdk"    "CAP saturate-reject (top performs <Foo>)" 'performs <Foo>'

echo "effect_set_domain: $pass/$fail"
[ "$fail" -eq 0 ]
