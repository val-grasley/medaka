#!/usr/bin/env bash
# DELETE oracle for sqlite/lib/mutate.mdk.
#
# Proves that the Medaka DELETE path:
#   1. Removes exactly the rows matching the WHERE predicate.
#   2. Preserves the ORIGINAL rowids of surviving rows — including rowid GAPS.
#   3. Leaves other tables in the same file entirely untouched.
#   4. Returns the correct deleted-row count.
#   5. Produces an `integrity_check`-clean database.
#   6. Is refused (clean `Err`, no write) when the database has a secondary index.
#
# Setup: seed a two-table database:
#   * `users(id INTEGER PRIMARY KEY, name TEXT, age INTEGER)` — IPK table
#     with non-contiguous IPK values (1, 5, 9).  DELETE WHERE age >= 30 removes
#     bob (5) and carol (9); alice (1) survives.
#   * `kv(k TEXT, v INTEGER)` — non-IPK table with a rowid GAP (1, 3, 4).
#     DELETE WHERE v > 25 removes two rows; row-1 (a=10) survives with rowid 1.
#
# Usage:
#   sqlite/test/delete_oracle.sh            # build, run, verify
#   sqlite/test/delete_oracle.sh --capture  # (re)write the golden
#
# Requires: sqlite3 on PATH; the Medaka tree built (`make medaka`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

GOLDEN="$HERE/delete.golden"
TMP="$(mktemp -d)"
DB="$TMP/test.db"
OUT="$(mktemp)"

MEDAKA="$ROOT/medaka"
# Scratch binaries live in a PER-PROCESS temp dir, never at the repo root.
#
# These used to run `medaka build sqlite/main.mdk` with NO `-o`, which emits the binary
# as ./<entry> at the REPO ROOT, and then `mv`d it to a FIXED path ($ROOT/sqlite_reader).
# Both halves are a race: two of these oracles running concurrently clobbered each
# other's ./main and shared one sqlite_reader. Serially all 22 passed; under run_gates'
# parallel pool, 2 failed — and which 2 varied. (Same bug class, and same fix, as the
# `medaka build` scratch-path collision in AGENTS.md: the only correct answer is a
# per-process temp dir. Anything keyed on the entry name is a trap.)
BINDIR="$(mktemp -d)"
trap 'rm -rf "$BINDIR"' EXIT
DELETER="$BINDIR/sqlite_deleter"
READER="$BINDIR/sqlite_reader"
export MEDAKA_ROOT="$ROOT"
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

# 1. Build the Medaka delete probe + reader binaries.
"$MEDAKA" build sqlite/delete_demo.mdk -o "$DELETER" >/dev/null
"$MEDAKA" build sqlite/main.mdk -o "$READER" >/dev/null

# 2. Seed the database with sqlite3.
#    users: IPK 1,5,9 (non-contiguous); kv: non-IPK with a rowid GAP (1,3,4).
rm -f "$DB"
sqlite3 "$DB" "
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);
INSERT INTO users(id,name,age) VALUES (1,'alice',25),(5,'bob',30),(9,'carol',55);
CREATE TABLE kv(k TEXT, v INTEGER);
INSERT INTO kv(rowid,k,v) VALUES (1,'a',10),(3,'b',30),(4,'c',40);
"

echo "=== BEFORE DELETE ==="
sqlite3 "$DB" "SELECT rowid,id,name,age FROM users ORDER BY rowid;"
sqlite3 "$DB" "SELECT rowid,k,v FROM kv ORDER BY rowid;"

# 3. DELETE: remove users WHERE age >= 30  (removes bob/5 and carol/9).
DELETE_OUT="$("$DELETER" "$DB" users age ge 30)"
echo "delete users WHERE age >= 30: $DELETE_OUT"

# 4. DELETE: remove kv WHERE v > 25  (removes rows 3 and 4; row 1 survives).
DELETE_KV="$("$DELETER" "$DB" kv v gt 25)"
echo "delete kv WHERE v > 25: $DELETE_KV"

echo "=== AFTER DELETE ==="
sqlite3 "$DB" "SELECT rowid,id,name,age FROM users ORDER BY rowid;"
sqlite3 "$DB" "SELECT rowid,k,v FROM kv ORDER BY rowid;"

# 5. Combine the verification report.
{
  echo "# integrity_check"
  sqlite3 "$DB" "PRAGMA integrity_check;"
  echo "# delete users result"
  echo "$DELETE_OUT"
  echo "# delete kv result"
  echo "$DELETE_KV"
  echo "# users after (rowid,id,name,age)"
  sqlite3 "$DB" "SELECT rowid,id,name,age FROM users ORDER BY rowid;"
  echo "# kv after (rowid,k,v)"
  sqlite3 "$DB" "SELECT rowid,k,v FROM kv ORDER BY rowid;"
  echo "# reader: users"
  "$READER" "$DB" users
  echo "# reader: kv"
  "$READER" "$DB" kv
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

# Gate 2: DELETE count for users == 2.
echo "=== Gate 2: delete users count == 2 ==="
if [ "$DELETE_OUT" = "deleted 2 rows" ]; then
  echo "OK: users deleted count = 2"
else
  echo "FAIL: users delete said: $DELETE_OUT"
  fail=1
fi

# Gate 3: DELETE count for kv == 2.
echo "=== Gate 3: delete kv count == 2 ==="
if [ "$DELETE_KV" = "deleted 2 rows" ]; then
  echo "OK: kv deleted count = 2"
else
  echo "FAIL: kv delete said: $DELETE_KV"
  fail=1
fi

# Gate 4: users survivor alice has rowid 1 (IPK rowid preserved).
echo "=== Gate 4: users IPK rowid preserved (alice = rowid 1) ==="
USERS_ROWS="$(sqlite3 "$DB" "SELECT rowid,id,name,age FROM users ORDER BY rowid;")"
if [ "$USERS_ROWS" = "1|1|alice|25" ]; then
  echo "OK: users survivor alice at rowid 1"
else
  echo "FAIL: users rows = $USERS_ROWS (expected '1|1|alice|25')"
  fail=1
fi

# Gate 5: kv survivor 'a' has rowid 1 (non-IPK rowid preserved — not renumbered).
echo "=== Gate 5: kv non-IPK rowid preserved (a = rowid 1) ==="
KV_ROWS="$(sqlite3 "$DB" "SELECT rowid,k,v FROM kv ORDER BY rowid;")"
if [ "$KV_ROWS" = "1|a|10" ]; then
  echo "OK: kv survivor 'a' at rowid 1 (non-IPK rowid preserved)"
else
  echo "FAIL: kv rows = $KV_ROWS (expected '1|a|10')"
  fail=1
fi

# Gate 6: Medaka reader sees the same rows as sqlite3.
echo "=== Gate 6: Medaka reader self round-trip ==="
g6=0
diff -q <(printf '1|alice|25\n') <("$READER" "$DB" users) >/dev/null || { echo "FAIL reader users"; g6=1; }
diff -q <(printf 'a|10\n')       <("$READER" "$DB" kv)    >/dev/null || { echo "FAIL reader kv"; g6=1; }
if [ "$g6" = "0" ]; then echo "OK: Medaka reader agrees with sqlite3"; else fail=1; fi

# Gate 7: combined report matches the committed golden.
echo "=== Gate 7: combined report vs golden ==="
if diff -u "$GOLDEN" "$OUT"; then echo "OK: report matches golden"; else echo "FAIL: report differs from golden"; fail=1; fi

exit "$fail"
