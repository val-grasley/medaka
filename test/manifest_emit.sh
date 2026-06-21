#!/bin/sh
# test/manifest_emit.sh — `medaka manifest` capability manifest emission gate.
#
# WS-1c of EFFECTS-CONFORMANCE-ROADMAP.md.  Verifies:
#   1. TOML golden output: correct key=value rendering (Prefix param → string,
#      ⊤ param → true).
#   2. Internal-label drop: Mut/Panic NEVER appear in the manifest.
#   3. Security-label inclusion: Stdout, Net, etc. DO appear.
#   4. Round-trip accept: manifest-derived --allow tokens → check-policy rc 0.
#   5. Tightened reject: narrowed param (non-matching prefix) → check-policy rc 1.
#
# Native-only gate (no OCaml oracle for `manifest` — it's a new native subcommand).
# Usage: sh test/manifest_emit.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/medaka"
export MEDAKA_ROOT="$ROOT"

[ -x "$NATIVE" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }

pass=0; fail=0

ok_case() {
  printf 'ok   %s\n' "$1"
  pass=$((pass+1))
}

fail_case() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  fail=$((fail+1))
}

# ── case 1: net_param_plugin.mdk — Prefix param renders as string ─────────────
# transform has inferred <Net "idp.example.com/api">
# Expected TOML:
#   [package.capabilities]
#   Net = "idp.example.com/api"
NET_FIX="$ROOT/test/check_policy_fixtures/net_param_plugin.mdk"
[ -f "$NET_FIX" ] || { fail_case "net-golden" "missing $NET_FIX"; }

if [ -f "$NET_FIX" ]; then
  got="$(perl -e 'alarm 90; exec @ARGV' "$NATIVE" manifest "$NET_FIX" --fn transform 2>&1)"
  expected='[package.capabilities]
Net = "idp.example.com/api"'
  if [ "$got" = "$expected" ]; then
    ok_case "net-golden (Prefix param renders as string)"
  else
    fail_case "net-golden" "expected $(printf '%s' "$expected" | head -2); got: $got"
  fi
fi

# ── case 2: manifest_mixed.mdk — Mut dropped, Stdout retained ────────────────
# entry has inferred <Mut, Stdout>; manifest must be:
#   [package.capabilities]
#   Stdout = true
# (Mut is internal → dropped; Stdout is security → retained; labels sorted ascending)
MIXED_FIX="$ROOT/test/check_policy_fixtures/manifest_mixed.mdk"
[ -f "$MIXED_FIX" ] || { fail_case "mixed-golden" "missing $MIXED_FIX"; }

if [ -f "$MIXED_FIX" ]; then
  got="$(perl -e 'alarm 90; exec @ARGV' "$NATIVE" manifest "$MIXED_FIX" --fn entry 2>&1)"
  expected='[package.capabilities]
Stdout = true'
  if [ "$got" = "$expected" ]; then
    ok_case "mixed-golden (Mut dropped, Stdout retained)"
  else
    fail_case "mixed-golden" "expected: $expected; got: $got"
  fi

  # Assert Mut does NOT appear
  if printf '%s' "$got" | grep -qF "Mut"; then
    fail_case "mut-absent" "Mut appeared in manifest: $got"
  else
    ok_case "mut-absent (internal Mut not in manifest)"
  fi

  # Assert Stdout DOES appear
  if printf '%s' "$got" | grep -qF "Stdout"; then
    ok_case "stdout-present (security Stdout in manifest)"
  else
    fail_case "stdout-present" "Stdout missing from manifest: $got"
  fi
fi

# ── case 3: round-trip accept ────────────────────────────────────────────────
# The manifest-derived --allow token for net_param_plugin is "Net=idp.example.com/api".
# check-policy with that exact allow must ACCEPT (rc 0).
# This proves the manifest is the exact verified authority (self ⊑ self).
if [ -f "$NET_FIX" ]; then
  rt_out="$(perl -e 'alarm 90; exec @ARGV' \
      "$NATIVE" check-policy "$NET_FIX" --allow "Net=idp.example.com/api" --fn transform 2>&1)"
  rt_rc=$?
  if [ "$rt_rc" = "0" ] && printf '%s' "$rt_out" | grep -qF "accepted"; then
    ok_case "round-trip-accept (manifest → check-policy rc=0)"
  else
    fail_case "round-trip-accept" "rc=$rt_rc output: $rt_out"
  fi
fi

# ── case 4: tightened reject ─────────────────────────────────────────────────
# Narrow the Net param to a NON-MATCHING prefix: other.com/api.
# The inferred <Net "idp.example.com/api"> is NOT ⊑ <Net "other.com/api">.
# check-policy must REJECT (rc 1).
if [ -f "$NET_FIX" ]; then
  tight_out="$(perl -e 'alarm 90; exec @ARGV' \
      "$NATIVE" check-policy "$NET_FIX" --allow "Net=other.com/api" --fn transform 2>&1)"
  tight_rc=$?
  if [ "$tight_rc" = "1" ] && printf '%s' "$tight_out" | grep -qF "rejected"; then
    ok_case "tightened-reject (narrowed param → check-policy rc=1)"
  else
    fail_case "tightened-reject" "rc=$tight_rc output: $tight_out"
  fi
fi

echo ""
printf '%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
