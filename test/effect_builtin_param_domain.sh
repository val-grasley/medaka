#!/bin/sh
# test/effect_builtin_param_domain.sh
#
# WS-3b gate for DOMAIN-DIRECTED inferred-hole fill on the REAL stdlib
# builtins `getEnv` (Env, Set domain), `runCommand` (Exec, Prefix domain), and
# (filerw-hole-flip) `readFile`/`writeFile` (FileRead/FileWrite, Prefix domain).
# Unlike test/effect_param_domain.sh (which uses per-program LOCAL extern
# redeclarations + a per-program `effect Env Set`/`effect Exec Prefix` decl),
# these fixtures call the stdlib/runtime.mdk builtins DIRECTLY — no local
# extern, no effect decl — because:
#   - Env/Exec/FileRead/FileWrite are already pre-registered as Set/Prefix
#     domains in seedEffectDomains (compiler/types/typecheck.mdk)
#   - stdlib/runtime.mdk's `getEnv`/`runCommand`/`readFile`/`writeFile` (and
#     the other 7 file-IO externs) now carry the universal inferred-hole
#     marker `<Env _>`/`<Exec _>`/`<FileRead _>`/`<FileWrite _>`
# `args` is deliberately NOT flipped (its arg is Unit — no literal to refine).
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

# FILEREAD (Prefix domain), REAL builtin readFile: prefix hole-fill
expect_ok     "$FIX/fileread_hole_accept.mdk" 'FILEREAD builtin hole-fill accept (/etc/app/config.toml ⊑ /etc/app/*)'
expect_reject "$FIX/fileread_hole_reject.mdk" 'FILEREAD builtin hole-fill reject (/etc/app/config.toml ⊄ /etc/other/*)' 'performs <FileRead "/etc/app/config.toml">'

# FILEWRITE (Prefix domain), REAL builtin writeFile: prefix hole-fill
expect_ok     "$FIX/filewrite_hole_accept.mdk" 'FILEWRITE builtin hole-fill accept (/var/log/app.log ⊑ /var/log/*)'
expect_reject "$FIX/filewrite_hole_reject.mdk" 'FILEWRITE builtin hole-fill reject (/var/log/app.log ⊄ /tmp/*)' 'performs <FileWrite "/var/log/app.log">'

# ── top-level PSet (Env) manifest + check-policy round-trip ──────────────────
# Regression for the missing top-level `PSet (Some xs)` arms in
# check_policy.mdk's atomToToml/atomToAllowTok/parsePolicyTok (Env is a
# top-level Set-domain param, not nested in a PProduct axis).
manifest_out() { perl -e 'alarm 60; exec @ARGV' -- "$M" manifest "$@" 2>&1; }
policy_out()   { perl -e 'alarm 60; exec @ARGV' -- "$M" check-policy "$@" 2>&1; }

# manifest render: FileRead top-level Prefix param renders as a TOML string
# (renders the DECLARED bound, not the refined call-site value).
mff="$(manifest_out "$FIX/fileread_hole_accept.mdk" --fn readCfg)"
mff_expected='[package.capabilities]
FileRead = "/etc/app/*"'
if [ "$mff" = "$mff_expected" ]; then
  echo "ok   FILEREAD manifest render (top-level PPrefix -> TOML string)"; pass=$((pass+1))
else
  echo "FAIL FILEREAD manifest render: expected: $mff_expected; got: $mff"; fail=$((fail+1))
fi

# manifest render: top-level Env set must render as a TOML array, not `Env = true`.
mf="$(manifest_out "$FIX/env_hole_accept.mdk" --fn readHome)"
mf_expected='[package.capabilities]
Env = ["HOME", "PATH"]'
if [ "$mf" = "$mf_expected" ]; then
  echo "ok   ENV manifest render (top-level PSet -> TOML array)"; pass=$((pass+1))
else
  echo "FAIL ENV manifest render: expected: $mf_expected; got: $mf"; fail=$((fail+1))
fi

# round-trip accept: the manifest-derived --allow token (Env={HOME,PATH})
# fed back through check-policy must ACCEPT (self ⊑ self).
rt="$(policy_out "$FIX/env_hole_accept.mdk" --allow 'Env={HOME,PATH}' --fn readHome)"
if echo "$rt" | grep -q '^accepted'; then
  echo "ok   ENV round-trip accept (manifest --allow token accepted by check-policy)"; pass=$((pass+1))
else
  echo "FAIL ENV round-trip accept: $rt"; fail=$((fail+1))
fi

# tightened reject: narrowed Env set ({PATH}, missing HOME) must REJECT, proving
# the policy compare treats the rhs as a Set (subsetStr), not a wrongly-rejecting
# PPrefix (which would hit dsubN's domain-mismatch catch-all regardless of value).
tr="$(policy_out "$FIX/env_hole_accept.mdk" --allow 'Env={PATH}' --fn readHome)"
if echo "$tr" | grep -q '^rejected' && echo "$tr" | grep -q 'Env {"HOME", "PATH"}'; then
  echo "ok   ENV tightened reject (Env={PATH} rejects getEnv \"HOME\")"; pass=$((pass+1))
else
  echo "FAIL ENV tightened reject: $tr"; fail=$((fail+1))
fi

echo "effect_builtin_param_domain: $pass/$fail"
[ "$fail" -eq 0 ]
