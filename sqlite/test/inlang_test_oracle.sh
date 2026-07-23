#!/usr/bin/env bash
# In-language (`medaka test`) gate for the SQLite dogfood library.
#
# Unlike the sibling *_oracle.sh gates (which diff the library against the real
# sqlite3 CLI), this gate runs the pure-Medaka `test "…"` / `prop "…"` suites
# under `sqlite/test/*_test.mdk` and asserts they are DISCOVERED and PASS.
#
# It lives in sqlite/test/ and matches the `sqlite` CI shard's glob
# ('sqlite/test/*oracle') exactly like its siblings, so run_gates.sh auto-enrolls
# it — no new ci.yml shard entry is needed.
#
# THE ANTI-ROT GUARD (docs/ops/TESTING-DESIGN.md §0: "this didn't run" is
# indistinguishable from "this passed"): a `medaka test` file with ZERO
# assertions exits 0 — vacuously green. So exit-0 alone is NOT enough. For every
# file we also COUNT the assertions that actually ran ("  ok   " test lines +
# "... OK (" prop lines) and fail if the count falls below a per-file floor. If
# discovery ever silently stops finding the decls, the count drops to 0 and this
# gate goes RED — which is the whole point.
#
# Run from the repo root. Requires a built native `medaka` ($MEDAKA / ../medaka);
# no sqlite3 and no emitter needed (`medaka test` runs the interpreter).
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_ROOT

[ -x "$MEDAKA" ] || { echo "build medaka first (missing $MEDAKA)"; exit 2; }

# file:floor — floor = the assertion count committed today. Adding tests only
# raises the real count (>= floor still passes); removing them, or a discovery
# regression, drops below the floor and fails. Raise a floor when you add tests.
SUITES="expr_test:19 query_test:13 roundtrip_test:7"

rc=0
total_ran=0
for spec in $SUITES; do
  name="${spec%%:*}"
  floor="${spec##*:}"
  path="$ROOT/sqlite/test/$name.mdk"
  if [ ! -f "$path" ]; then
    echo "FAIL: $name.mdk missing at $path"; rc=1; continue
  fi

  out="$("$MEDAKA" test "$path" 2>&1)"
  code=$?

  # Assertions that actually executed: passing `test` lines + passing `prop` lines.
  ok_tests=$(printf '%s\n' "$out" | grep -c '^  ok   ')
  ok_props=$(printf '%s\n' "$out" | grep -c '\.\.\. OK (')
  ran=$((ok_tests + ok_props))
  total_ran=$((total_ran + ran))

  if [ "$code" -ne 0 ]; then
    echo "FAIL: $name.mdk — medaka test exited $code (assertion failed)"
    printf '%s\n' "$out"
    rc=1
    continue
  fi
  if [ "$ran" -lt "$floor" ]; then
    echo "FAIL: $name.mdk — only $ran assertions ran, expected >= $floor (vacuous-green guard: discovery may have silently stopped finding tests)"
    printf '%s\n' "$out"
    rc=1
    continue
  fi
  echo "PASS: $name.mdk — $ran assertions ran (floor $floor)"
done

if [ "$total_ran" -eq 0 ]; then
  echo "FAIL: no assertions ran at all across the sqlite in-language suite"
  exit 1
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: sqlite in-language test suite ($total_ran assertions across the suite)"
fi
exit "$rc"
