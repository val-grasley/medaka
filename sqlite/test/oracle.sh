#!/usr/bin/env bash
# Differential oracle for the Medaka SQLite read-path library.
#
# Generates a fresh .db from the checked-in SQL via the real sqlite3 CLI, then
# reads it BOTH with sqlite3 (the oracle) and the compiled Medaka reader, and
# diffs.  The binary .db is regenerated each run (never committed); only the SQL
# and the captured goldens live in git.
#
# Tables in basic.sql (all single table-leaf root pages):
#   users  — INTEGER PRIMARY KEY + TEXT + nullable INTEGER
#   items  — UTF-8 text + multi-width / negative integers
#   notes  — a table with no INTEGER PRIMARY KEY
#
# Usage:
#   sqlite/test/oracle.sh            # build reader, generate db, diff vs sqlite3
#   sqlite/test/oracle.sh --capture  # (re)write the golden files
#
# Requires: sqlite3 on PATH; the Medaka tree built (`make medaka`).
set -euo pipefail

# Resolve the repo root (this script lives in <root>/sqlite/test/).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

SQL="$HERE/basic.sql"
GOLDEN="$HERE/basic.golden"
DB="$(mktemp -d)/basic.db"
OUT="$(mktemp)"

MEDAKA="$ROOT/medaka"
READER="$ROOT/sqlite_reader"
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

# 1. Build the Medaka reader binary from sqlite/main.mdk.
"$MEDAKA" build sqlite/main.mdk >/dev/null
# `medaka build` emits the binary as ./main; rename to a stable name.
mv -f "$ROOT/main" "$READER"

# 2. Generate the test database from the checked-in SQL.
rm -f "$DB"
sqlite3 "$DB" < "$SQL"

# 3. Produce the combined report from the Medaka reader.
{
  echo "# schema"
  "$READER" "$DB"
  for t in users items notes; do
    echo "# table $t"
    "$READER" "$DB" "$t"
  done
} > "$OUT"

if [ "${1:-}" = "--capture" ]; then
  cp "$OUT" "$GOLDEN"
  echo "captured golden -> $GOLDEN"
  cat "$GOLDEN"
  exit 0
fi

# 4. Build the EXPECTED report from sqlite3 directly (the oracle) and check the
#    Medaka reader matches it, AND matches the committed golden.
ORACLE="$(mktemp)"
{
  echo "# schema"
  sqlite3 "$DB" "SELECT type, name, rootpage FROM sqlite_master"
  for t in users items notes; do
    echo "# table $t"
    sqlite3 "$DB" "SELECT * FROM $t"
  done
} > "$ORACLE"

fail=0
echo "=== Medaka reader vs sqlite3 oracle ==="
if diff -u "$ORACLE" "$OUT"; then
  echo "OK: Medaka reader output matches sqlite3"
else
  echo "FAIL: Medaka reader differs from sqlite3"
  fail=1
fi

echo "=== Medaka reader vs committed golden ==="
if diff -u "$GOLDEN" "$OUT"; then
  echo "OK: Medaka reader output matches golden"
else
  echo "FAIL: Medaka reader differs from golden"
  fail=1
fi

exit "$fail"
