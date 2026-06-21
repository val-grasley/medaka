#!/bin/sh
# test/effect_param_domain.sh
#
# WS-3b NATIVE-ONLY gate for DOMAIN-DIRECTED inferred-hole fill on the Env (Set)
# and Exec (Prefix) effect domains.  An extern annotated `<Env _>` / `<Exec _>`
# carries the universal inferred-hole marker `_`; the call-site abstraction α
# recovers the literal first argument and the hole-fill builds the param shape of
# the LABEL's domain:
#   Set   domain (Env)  → a singleton authority set  <Env {"HOME"}>
#   Prefix domain (Exec) → a prefix pattern          <Exec "/usr/bin/ls">
# Multiple Env calls join by set UNION (∪).  Confinement is the standard escape
# check against a declared bound.
#
# NATIVE-ONLY: the frozen OCaml oracle classifies both `Env` and `Exec` as ATOMIC
# security labels (PUnit) and has no Set domain, so it cannot parse `<Env _>` /
# `<Exec _>` nor `<Env {…}>`.  This gate therefore exercises `./medaka check`
# ALONE (no differential oracle), exactly like effect_set_domain.sh.  These
# fixtures DECLARE their domains per-program (`effect Env Set` / `effect Exec
# Prefix`) and use LOCAL externs, so the shared stdlib/runtime.mdk is untouched —
# this keeps the oracle-gated check-policy/typecheck diffs green.
#
# Prereq: `make medaka` (native CLI).  Usage: sh test/effect_param_domain.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/medaka"
FIX="$ROOT/test/effect_param_fixtures"
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

# ENV (Set domain): singleton fill + ∪ join
expect_ok     "$FIX/env_hole_accept.mdk"  "ENV  hole-fill accept ({HOME} ⊆ {HOME,PATH})"
expect_reject "$FIX/env_hole_reject.mdk"  "ENV  hole-fill reject ({HOME} ⊄ {PATH})"   'performs <Env {"HOME"}>'
expect_ok     "$FIX/env_join_accept.mdk"  "ENV  djoin ∪ accept ({A,B} ⊆ {A,B})"
expect_reject "$FIX/env_join_reject.mdk"  "ENV  djoin ∪ reject ({A,B} ⊄ {A})"         'performs <Env {"A", "B"}>'

# EXEC (Prefix domain): prefix fill + prefix subsumption
expect_ok     "$FIX/exec_hole_accept.mdk" 'EXEC hole-fill accept (/usr/bin/ls ⊑ /usr/bin/*)'
expect_reject "$FIX/exec_hole_reject.mdk" 'EXEC hole-fill reject (/usr/bin/ls ⊄ /bin/*)' 'performs <Exec "/usr/bin/ls">'

echo "effect_param_domain: $pass/$fail"
[ "$fail" -eq 0 ]
