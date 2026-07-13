#!/bin/sh
# test/effect_product_domain.sh
#
# WS-4 NATIVE-ONLY gate for the PRODUCT refinement domain — a structure-aware
# `Net = Host(Prefix) x Method(Set)`.  A program opts in with `effect Net Product`
# and writes structured literals `<Net Host="…" Method={…}>` (keyword-axes,
# capitalized; Option A of archive/design/WS-4-DESIGN.md).  Confinement is the standard escape
# check against a declared bound, now POINTWISE over the two axes — Host and Method
# confine INDEPENDENTLY (the WS-4 headline).
#
# NATIVE-ONLY: the frozen OCaml oracle has no Set/Product domain and cannot parse
# `effect Net Product` nor a product literal, so this gate exercises `./medaka
# check` / `medaka check-policy` ALONE (no differential oracle), exactly like
# effect_param_domain.sh / effect_set_domain.sh.  All fixtures DECLARE their domain
# per-program and use LOCAL externs, so the shared stdlib/runtime.mdk is untouched
# (keeps the oracle-gated canary diffs byte-identical).
#
# Prereq: `make medaka` (native CLI).  Usage: sh test/effect_product_domain.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/medaka"
FIX="$ROOT/test/effect_product_fixtures"
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
# expect REJECT: output must contain the expected performs-row text
expect_reject() {
  out="$(run "$1")"
  if echo "$out" | grep -q "$3"; then
    echo "ok   $2"; pass=$((pass+1))
  else echo "FAIL $2 (expected reject matching '$3'):"; echo "$out" | grep -iE 'error' | head -2; fail=$((fail+1)); fi
}

# ── Independent host+method confinement (the WS-4 headline) ──────────────────
expect_ok     "$FIX/prod_accept.mdk"        "PROD accept (host in-prefix AND method in-set)"
expect_reject "$FIX/prod_reject_host.mdk"   "PROD reject HOST out-of-prefix"   'performs <Net Host="other.com/api" Method={"GET"}>'
expect_reject "$FIX/prod_reject_method.mdk" "PROD reject METHOD out-of-set"    'performs <Net Host="idp.example.com/api" Method={"POST"}>'

# ── Soundness: inferred omits Method (=> TOP on Method), bound confines Method.
# A buggy axis-defaulting dsubN (skip missing inferred axes) would ACCEPT; the
# sound one looks the missing axis up against the bound axis sub-TOP and REJECTS.
expect_reject "$FIX/prod_soundness.mdk"     "PROD soundness (TOP-method !<= confined-method)" 'performs <Net Host="idp.example.com/api">'

# ── Host-axis lift: a bare `<Net "…">` under a Product Net = Host-only, Method=TOP.
expect_ok     "$FIX/prod_host_lift.mdk"     "PROD host-axis lift (bare host literal under product Net)"

# ── Backward-compat: a bare Prefix Net (NOT opt-in) behaves exactly as before.
expect_ok     "$FIX/prod_compat_prefix.mdk" "PROD backward-compat (Prefix Net unchanged)"

# ── check-policy with a PRODUCT policy: accept when the policy product admits,
# reject when an axis (Method) is too narrow.  Policy axis form: `Host="…";Method={…}`
# (';'-separated axes; the brace-aware comma split keeps `{…}` intact).
PLUG="$FIX/prod_policy_plugin.mdk"
cp_accept_out="$(perl -e 'alarm 90; exec @ARGV' -- "$M" check-policy "$PLUG" \
  --allow 'Net=Host="idp.example.com/*";Method={GET,POST}' --fn transform 2>&1)"
if echo "$cp_accept_out" | grep -q '^accepted'; then
  echo "ok   PROD check-policy accept (policy product admits)"; pass=$((pass+1))
else
  echo "FAIL PROD check-policy accept:"; echo "$cp_accept_out" | head -2; fail=$((fail+1)); fi

cp_reject_out="$(perl -e 'alarm 90; exec @ARGV' -- "$M" check-policy "$PLUG" \
  --allow 'Net=Host="idp.example.com/*";Method={GET}' --fn transform 2>&1)"
if echo "$cp_reject_out" | grep -q '^rejected'; then
  echo "ok   PROD check-policy reject (policy Method too narrow)"; pass=$((pass+1))
else
  echo "FAIL PROD check-policy reject:"; echo "$cp_reject_out" | head -2; fail=$((fail+1)); fi

echo "effect_product_domain: $pass/$fail"
[ "$fail" -eq 0 ]
