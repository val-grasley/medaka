#!/bin/sh
# DRIVER-COLLAPSE Phase 4 (OPTION A) capability gate: the real `medaka check` CLI
# now RESOLVES imports (loadProgram → multi-module typecheck), fixing the "native
# check is single-file" limitation.  This gate proves the new capability and that
# `check` AGREES with `build` on the SAME project (both route through the unified
# loader + elaborateModules path → the same hadTypeErrors verdict).
#
# It complements (does NOT duplicate):
#   • diff_selfhost_check.sh         — single-file check_main host; no-import
#     byte-identity + UnknownModule for genuinely-missing imports (unchanged).
#   • diff_selfhost_check_modules.sh — native multi typecheck vs the OCaml MULTI
#     oracle goldens (the import-aware path check now shares with run/build).
#   • diff_native_cli.sh check/*     — the CLI's no-import goldens (byte-identical).
#
# Drives ./medaka (must be freshly built — make medaka — see the diff_native_cli
# stale-binary footgun: this gate NEVER rebuilds it).
#
# Legs (all on a synthesized 2-file project with a cross-module import):
#   1. resolve:  `check main.mdk` resolves `import helper.{double}` — output names
#                the cross-module-typed binding and emits NO `UnknownModule`.
#   2. exit0:    a well-typed import-bearing project exits 0.
#   3. type-err: a type-error import-bearing project emits a TYPE ERROR and exits 1.
#   4. agree:    on that type-error project, `build` ALSO rejects (exit 1) — check
#                and build agree via the unified path.
#
# Usage:  sh test/diff_selfhost_check_cli_modules.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }
strip_unit() { sed '$ s/0$//'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# A small 2-file project: main imports a public helper from a sibling module.
cat > "$TMP/helper.mdk" <<'EOF'
export double : Int -> Int
double x = x + x
EOF
cat > "$TMP/good.mdk" <<'EOF'
import helper.{double}
quad : Int -> Int
quad x = double (double x)
main = println (quad 3)
EOF
cat > "$TMP/bad.mdk" <<'EOF'
import helper.{double}
bad : Int
bad = double "x"
EOF

# 1. resolve: import resolved (quad typed) AND no UnknownModule diagnostic.
good_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/good.mdk" 2>/dev/null | strip_unit)"
good_code=$?
case "$good_out" in
  *UnknownModule*) fail=$((fail+1)); printf 'FAIL resolve/import (still UnknownModule: %s)\n' "$good_out" ;;
  *"quad : Int -> Int"*) pass=$((pass+1)); printf 'ok   resolve/import (cross-module reference typed)\n' ;;
  *) fail=$((fail+1)); printf 'FAIL resolve/import (no quad scheme: [%s])\n' "$good_out" ;;
esac

# 2. exit0: well-typed import-bearing project exits 0.
MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/good.mdk" >/dev/null 2>&1
if [ "$?" -eq 0 ]; then pass=$((pass+1)); printf 'ok   exit0/good\n'
else fail=$((fail+1)); printf 'FAIL exit0/good (exit %d)\n' "$?"; fi

# 3. type-err: import-bearing type error → TYPE ERROR + exit 1.
bad_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/bad.mdk" 2>/dev/null)"
bad_code=$?
case "$bad_out" in
  *"TYPE ERROR"*) if [ "$bad_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   type-err/bad (TYPE ERROR, exit 1)\n'
                  else fail=$((fail+1)); printf 'FAIL type-err/bad (TYPE ERROR but exit %d)\n' "$bad_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL type-err/bad (no TYPE ERROR: [%s])\n' "$bad_out" ;;
esac

# 4. agree: build rejects the SAME type-error project (exit 1) — check==build.
MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/bad.mdk" -o "$TMP/bad.out" >/dev/null 2>&1
build_code=$?
if [ "$build_code" -ne 0 ] && [ ! -x "$TMP/bad.out" ]; then
  pass=$((pass+1)); printf 'ok   agree/build-rejects (check & build both reject)\n'
else
  fail=$((fail+1)); printf 'FAIL agree/build-rejects (build exit %d, binary present=%s)\n' "$build_code" "$([ -x "$TMP/bad.out" ] && echo yes || echo no)"
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
