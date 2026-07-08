#!/bin/sh
# P0-13 regression: module resolution used to be findProjectRoot-only (a SINGLE
# non-stdlib root), so an entry file living in a subdir of a project that HAS a
# medaka.toml at its root could not resolve a bare sibling import next to itself
# — `medaka run src/main.mdk` (import helper.{greet}; helper.mdk is src/helper.mdk)
# failed with "unknown module: helper" when invoked from the project root (or an
# absolute path, or any other cwd), while `(cd src && medaka run main.mdk)` worked
# (there, findProjectRoot's fallback happens to equal src/ since no medaka.toml
# was found above — the moment medaka.toml is added at the root, that fallback
# stops helping).
#
# Fix: driver.loader.entrySearchRoots returns [entryDir, projectRoot] (deduped)
# instead of a single findProjectRoot root; medaka_cli.mdk (run/check/build/test)
# and build_cmd.mdk (native + wasm emit driver arg lists) now all use it.
#
# This gate locks the fix across all four subcommands, from three different
# cwd/path shapes: project root (relative), inside src/ (relative), and an
# absolute path from an unrelated cwd. No subshells are used for the checks
# themselves (only `cd` is scoped via pushd-style save/restore) so pass/fail
# counters aren't lost to a subshell.
#
# Usage:  sh test/diff_compiler_run_entry_subdir.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

mkdir -p "$TMP/proj/src"
cat > "$TMP/proj/medaka.toml" <<'EOF'
[project]
name = "p0-13-subdir"
entry = "src/main.mdk"
EOF
cat > "$TMP/proj/src/helper.mdk" <<'EOF'
export greet : String
greet = "hello from helper"
EOF
cat > "$TMP/proj/src/main.mdk" <<'EOF'
import helper.{greet}
main = println greet
EOF

export MEDAKA_ROOT="$ROOT"
START="$(pwd)"

check() {
  label="$1"; shift
  out="$(bound "$@" 2>&1)"
  code=$?
  if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q 'hello from helper'; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    printf 'FAIL %s (exit=%s): %s\n' "$label" "$code" "$out"
  fi
}

check_no_unknown_module() {
  label="$1"; shift
  out="$(bound "$@" 2>&1)"
  code=$?
  case "$out" in
    *"unknown module"*|*UnknownModule*)
      fail=$((fail+1)); printf 'FAIL %s (unknown module): %s\n' "$label" "$out" ;;
    *)
      if [ "$code" -eq 0 ]; then
        pass=$((pass+1))
      else
        fail=$((fail+1)); printf 'FAIL %s (exit=%s): %s\n' "$label" "$code" "$out"
      fi
      ;;
  esac
}

# 1. run, from the project root, relative entry path.
cd "$TMP/proj"
check 'run/root' "$MEDAKA" run src/main.mdk

# 2. run, from inside src/ (regression baseline — this direction always worked).
cd "$TMP/proj/src"
check 'run/insidesrc' "$MEDAKA" run main.mdk

# 3. run, absolute path from an unrelated cwd.
cd "$TMP"
check 'run/abspath' "$MEDAKA" run "$TMP/proj/src/main.mdk"

# 4. check, from the project root — must resolve `helper` (no UnknownModule) and
#    print the inferred scheme, not an error.
cd "$TMP/proj"
check_no_unknown_module 'check/root' "$MEDAKA" check src/main.mdk

# 5. build + run the binary, from the project root.
outbin="$TMP/p0_13_out"
build_out="$(bound "$MEDAKA" build src/main.mdk -o "$outbin" 2>&1)"
build_code=$?
if [ "$build_code" -ne 0 ]; then
  fail=$((fail+1)); printf 'FAIL build/root (exit=%s): %s\n' "$build_code" "$build_out"
else
  run_out="$(bound "$outbin" 2>&1)"
  if printf '%s' "$run_out" | grep -q 'hello from helper'; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); printf 'FAIL build/root binary output: %s\n' "$run_out"
  fi
fi

# 6. test (doctests) from the project root — must not error on the import; a
#    project with no doctests reports "(no doctests found)" cleanly.
check_no_unknown_module 'test/root' "$MEDAKA" test src/main.mdk

cd "$START"
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
