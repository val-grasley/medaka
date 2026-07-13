#!/usr/bin/env bash
# NEGATIVE oracle for sqlite/lib/mutate.mdk — proves the refusal guard.
#
# Seeds a database WITH a secondary index, then calls `delete`, and asserts:
#   1. The call returns the clean `Err` string (no write occurs).
#   2. The database file is NOT modified (bit-for-bit identical to the seed).
#
# Usage:
#   sqlite/test/delete_negative_oracle.sh            # run, verify
#   sqlite/test/delete_negative_oracle.sh --capture  # (re)write the golden
#
# Requires: sqlite3 on PATH; the Medaka tree built (`make medaka`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

GOLDEN="$HERE/delete_negative.golden"
TMP="$(mktemp -d)"
DB="$TMP/indexed.db"
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
export MEDAKA_ROOT="$ROOT"
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

# 1. Build the delete probe.
"$MEDAKA" build sqlite/delete_demo.mdk -o "$DELETER" >/dev/null

# 2. Seed a database WITH a secondary index.
rm -f "$DB"
sqlite3 "$DB" "
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);
CREATE INDEX idx_age ON users(age);
INSERT INTO users(id,name,age) VALUES (1,'alice',25),(2,'bob',30);
"

# 3. Snapshot the db bytes before the attempted delete.
cp "$DB" "$TMP/before.db"

# 4. Attempt the delete — should return Err, NOT write.
DELETE_OUT="$("$DELETER" "$DB" users age gt 0)"
echo "delete result: $DELETE_OUT"

# 5. Report.
{
  echo "# delete result"
  echo "$DELETE_OUT"
  echo "# db unchanged (0 = identical)"
  cmp -s "$TMP/before.db" "$DB" && echo "0" || echo "1"
  echo "# sqlite3 still readable (integrity_check)"
  sqlite3 "$DB" "PRAGMA integrity_check;"
  echo "# rows still present"
  sqlite3 "$DB" "SELECT rowid,id,name,age FROM users ORDER BY rowid;"
} > "$OUT"

if [ "${1:-}" = "--capture" ]; then
  cp "$OUT" "$GOLDEN"
  echo "captured golden -> $GOLDEN"
  cat "$GOLDEN"
  exit 0
fi

fail=0

# Gate 1: returned the expected error string.
echo "=== Gate 1: correct error string ==="
EXPECTED="Error: cannot mutate: database has indexes (would be silently dropped)"
if [ "$DELETE_OUT" = "$EXPECTED" ]; then
  echo "OK: got expected Err: $DELETE_OUT"
else
  echo "FAIL: got '$DELETE_OUT' (expected '$EXPECTED')"
  fail=1
fi

# Gate 2: db file NOT modified.
echo "=== Gate 2: database file not modified ==="
if cmp -s "$TMP/before.db" "$DB"; then
  echo "OK: database file is bit-for-bit unchanged"
else
  echo "FAIL: database file was modified despite the Err"
  fail=1
fi

# Gate 3: db is still valid (rows intact, integrity_check ok).
echo "=== Gate 3: database still valid after refused mutation ==="
IC="$(sqlite3 "$DB" "PRAGMA integrity_check;")"
ROWS="$(sqlite3 "$DB" "SELECT count(*) FROM users;")"
if [ "$IC" = "ok" ] && [ "$ROWS" = "2" ]; then
  echo "OK: integrity_check = ok, rows intact (count=2)"
else
  echo "FAIL: integrity=$IC rows=$ROWS"
  fail=1
fi

# Gate 4: combined report matches golden.
echo "=== Gate 4: combined report vs golden ==="
if diff -u "$GOLDEN" "$OUT"; then echo "OK: report matches golden"; else echo "FAIL: report differs from golden"; fail=1; fi

exit "$fail"
