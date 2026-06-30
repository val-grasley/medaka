#!/usr/bin/env bash
# UPDATE oracle for sqlite/lib/mutate.mdk.
#
# Proves that the Medaka UPDATE path:
#   1. Updates exactly the rows matching the WHERE predicate.
#   2. Preserves the ORIGINAL rowids of all rows — including rowid GAPS.
#   3. Leaves other tables in the same file entirely untouched.
#   4. Returns the correct updated-row count.
#   5. Produces an `integrity_check`-clean database.
#
# Also proves the NEGATIVE case:
#   6. Attempting to SET the INTEGER PRIMARY KEY column returns a clean `Err`
#      and leaves the file bit-for-bit unchanged.
#
# Setup: seed a two-table database:
#   * `users(id INTEGER PRIMARY KEY, name TEXT, age INTEGER)` — IPK table
#     with non-contiguous IPK values (1, 5, 9).
#     UPDATE SET age=99 WHERE age >= 30 updates bob (5) and carol (9); alice (1) unchanged.
#   * `kv(k TEXT, v INTEGER)` — non-IPK table with a rowid GAP (1, 3, 4).
#     UPDATE SET v=0 WHERE v > 25 updates rows 3 and 4; row 1 (a=10) unchanged.
#
# Usage:
#   sqlite/test/update_oracle.sh            # build, run, verify
#   sqlite/test/update_oracle.sh --capture  # (re)write the golden
#
# Requires: sqlite3 on PATH; the Medaka tree built (`make medaka`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

GOLDEN="$HERE/update.golden"
TMP="$(mktemp -d)"
DB="$TMP/test.db"
DB_IPK="$TMP/ipk.db"
OUT="$(mktemp)"

MEDAKA="$ROOT/medaka"
UPDATER="$ROOT/sqlite_updater"
export MEDAKA_ROOT="$ROOT"
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

# 1. Build the Medaka update probe binary.
"$MEDAKA" build sqlite/update_demo.mdk >/dev/null
mv -f "$ROOT/update_demo" "$UPDATER"

# 2. Seed the main test database with sqlite3.
#    users: IPK 1,5,9 (non-contiguous); kv: non-IPK with a rowid GAP (1,3,4).
rm -f "$DB"
sqlite3 "$DB" "
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);
INSERT INTO users(id,name,age) VALUES (1,'alice',25),(5,'bob',30),(9,'carol',55);
CREATE TABLE kv(k TEXT, v INTEGER);
INSERT INTO kv(rowid,k,v) VALUES (1,'a',10),(3,'b',30),(4,'c',40);
"

echo "=== BEFORE UPDATE ==="
sqlite3 "$DB" "SELECT rowid,id,name,age FROM users ORDER BY rowid;"
sqlite3 "$DB" "SELECT rowid,k,v FROM kv ORDER BY rowid;"

# 3. UPDATE users: SET age=99 WHERE age >= 30  (updates bob/5 and carol/9).
UPDATE_USERS="$("$UPDATER" "$DB" users age int 99 age ge 30)"
echo "update users SET age=99 WHERE age >= 30: $UPDATE_USERS"

# 4. UPDATE kv: SET v=0 WHERE v > 25  (updates rows 3 and 4; row 1 unchanged).
UPDATE_KV="$("$UPDATER" "$DB" kv v int 0 v gt 25)"
echo "update kv SET v=0 WHERE v > 25: $UPDATE_KV"

echo "=== AFTER UPDATE ==="
sqlite3 "$DB" "SELECT rowid,id,name,age FROM users ORDER BY rowid;"
sqlite3 "$DB" "SELECT rowid,k,v FROM kv ORDER BY rowid;"

# 5. NEGATIVE: seed a db and try to SET the IPK column.
rm -f "$DB_IPK"
sqlite3 "$DB_IPK" "
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);
INSERT INTO users(id,name,age) VALUES (1,'alice',25),(2,'bob',30);
"
cp "$DB_IPK" "$TMP/ipk_before.db"
IPK_OUT="$("$UPDATER" "$DB_IPK" users id int 999 age ge 0)"
echo "update IPK column result: $IPK_OUT"

# 6. Combine the verification report.
{
  echo "# integrity_check users/kv db"
  sqlite3 "$DB" "PRAGMA integrity_check;"
  echo "# update users result"
  echo "$UPDATE_USERS"
  echo "# update kv result"
  echo "$UPDATE_KV"
  echo "# users after (rowid,id,name,age)"
  sqlite3 "$DB" "SELECT rowid,id,name,age FROM users ORDER BY rowid;"
  echo "# kv after (rowid,k,v)"
  sqlite3 "$DB" "SELECT rowid,k,v FROM kv ORDER BY rowid;"
  echo "# negative: SET IPK column result"
  echo "$IPK_OUT"
  echo "# negative: db unchanged (0 = identical)"
  cmp -s "$TMP/ipk_before.db" "$DB_IPK" && echo "0" || echo "1"
} > "$OUT"

if [ "${1:-}" = "--capture" ]; then
  cp "$OUT" "$GOLDEN"
  echo "captured golden -> $GOLDEN"
  cat "$GOLDEN"
  exit 0
fi

fail=0

# Gate 1: integrity_check == ok.
echo "=== Gate 1: PRAGMA integrity_check ==="
IC="$(sqlite3 "$DB" "PRAGMA integrity_check;")"
if [ "$IC" = "ok" ]; then echo "OK: integrity_check = ok"; else echo "FAIL: integrity_check = $IC"; fail=1; fi

# Gate 2: UPDATE count for users == 2.
echo "=== Gate 2: update users count == 2 ==="
if [ "$UPDATE_USERS" = "updated 2 rows" ]; then
  echo "OK: users updated count = 2"
else
  echo "FAIL: users update said: $UPDATE_USERS"
  fail=1
fi

# Gate 3: UPDATE count for kv == 2.
echo "=== Gate 3: update kv count == 2 ==="
if [ "$UPDATE_KV" = "updated 2 rows" ]; then
  echo "OK: kv updated count = 2"
else
  echo "FAIL: kv update said: $UPDATE_KV"
  fail=1
fi

# Gate 4: users — updated rows have new values, alice unchanged, rowids preserved.
echo "=== Gate 4: users rows correct after UPDATE ==="
USERS_ROWS="$(sqlite3 "$DB" "SELECT rowid,id,name,age FROM users ORDER BY rowid;")"
EXPECTED_USERS="1|1|alice|25
5|5|bob|99
9|9|carol|99"
if [ "$USERS_ROWS" = "$EXPECTED_USERS" ]; then
  echo "OK: users rows correct (alice unchanged, bob/carol updated, rowids 1/5/9 preserved)"
else
  echo "FAIL: users rows = $USERS_ROWS (expected rowids 1/5/9 with bob/carol age=99)"
  fail=1
fi

# Gate 5: kv — updated rows have new values, 'a' unchanged, rowid GAP preserved.
echo "=== Gate 5: kv non-IPK rowids preserved after UPDATE ==="
KV_ROWS="$(sqlite3 "$DB" "SELECT rowid,k,v FROM kv ORDER BY rowid;")"
EXPECTED_KV="1|a|10
3|b|0
4|c|0"
if [ "$KV_ROWS" = "$EXPECTED_KV" ]; then
  echo "OK: kv rows correct (a unchanged, b/c updated, rowid gap 1/3/4 preserved)"
else
  echo "FAIL: kv rows = $KV_ROWS (expected rowids 1/3/4 with b/c v=0)"
  fail=1
fi

# Gate 6: negative — SET IPK column returns the clean Err.
echo "=== Gate 6: SET IPK column refused ==="
EXPECTED_IPK="Error: cannot UPDATE the INTEGER PRIMARY KEY column"
if [ "$IPK_OUT" = "$EXPECTED_IPK" ]; then
  echo "OK: IPK set refused with: $IPK_OUT"
else
  echo "FAIL: got '$IPK_OUT' (expected '$EXPECTED_IPK')"
  fail=1
fi

# Gate 7: negative — db file NOT modified after refused UPDATE.
echo "=== Gate 7: database file not modified after IPK refusal ==="
if cmp -s "$TMP/ipk_before.db" "$DB_IPK"; then
  echo "OK: database file is bit-for-bit unchanged after IPK refusal"
else
  echo "FAIL: database file was modified despite the Err"
  fail=1
fi

# Gate 8: combined report matches the committed golden.
echo "=== Gate 8: combined report vs golden ==="
if diff -u "$GOLDEN" "$OUT"; then echo "OK: report matches golden"; else echo "FAIL: report differs from golden"; fail=1; fi

exit "$fail"
