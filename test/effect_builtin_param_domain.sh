#!/bin/sh
# test/effect_builtin_param_domain.sh
#
# WS-3b gate for DOMAIN-DIRECTED inferred-hole fill on the REAL stdlib
# builtins `getEnv` (Env, Set domain) and `runCommand` (Exec, Prefix domain).
# Unlike test/effect_param_domain.sh (which uses per-program LOCAL extern
# redeclarations + a per-program `effect Env Set`/`effect Exec Prefix` decl),
# these fixtures call the stdlib/runtime.mdk builtins DIRECTLY — no local
# extern, no effect decl — because:
#   - Env/Exec are already pre-registered as Set/Prefix domains in
#     seedEffectDomains (compiler/types/typecheck.mdk)
#   - stdlib/runtime.mdk's `getEnv`/`runCommand` now carry the universal
#     inferred-hole marker `<Env _>`/`<Exec _>` (WS-3b env/exec flip)
# `args` is deliberately NOT flipped (its arg is Unit — no literal to refine)
# and readFile/writeFile/listDir/etc (FileRead/FileWrite) are a separate,
# later, out-of-scope stage.
#
# Prereq: `make medaka` (native CLI).  Usage: sh test/effect_builtin_param_domain.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/medaka"
FIX="$ROOT/test/effect_builtin_param_fixtures"
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

# ENV (Set domain), REAL builtin getEnv: singleton hole-fill
expect_ok     "$FIX/env_hole_accept.mdk"  "ENV builtin  hole-fill accept ({HOME} ⊆ {HOME,PATH})"
expect_reject "$FIX/env_hole_reject.mdk"  "ENV builtin  hole-fill reject ({HOME} ⊄ {PATH})"   'performs <Env {"HOME"}>'

# EXEC (Prefix domain), REAL builtin runCommand: prefix hole-fill
expect_ok     "$FIX/exec_hole_accept.mdk" 'EXEC builtin hole-fill accept (/usr/bin/ls ⊑ /usr/bin/*)'
expect_reject "$FIX/exec_hole_reject.mdk" 'EXEC builtin hole-fill reject (/usr/bin/ls ⊄ /bin/*)' 'performs <Exec "/usr/bin/ls">'

echo "effect_builtin_param_domain: $pass/$fail"
[ "$fail" -eq 0 ]
