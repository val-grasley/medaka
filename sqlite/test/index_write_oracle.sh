#!/usr/bin/env bash
# Differential oracle for the Medaka SQLite CREATE INDEX write path
# (writer.mdk `writeTableWithIndexes` -> dbwriter.mdk
# `buildDatabaseMultiWithIndexes`).
#
# Builds ONE `.sqlite` file FROM SCRATCH with the Medaka writer, containing one
# table plus TWO single-column secondary indexes, then checks that REAL sqlite3
# accepts and uses them:
#
#   CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT, age INTEGER)
#     1 bob 30 / 2 alice 25 / 3 carol NULL / 4 bob 40 / 5 dave 25
#   CREATE INDEX idx_name ON people(name)   -- TEXT-keyed  (dup "bob")
#   CREATE INDEX idx_age  ON people(age)    -- INT-keyed   (NULL key + dup 25)
#
# Gates:
#   1. sqlite3 PRAGMA integrity_check == "ok"  (THE bar: any wrong index record
#      encoding, sort order, page type, or rootpage fails this instantly).
#   2. sqlite_master lists both indexes with correct type/name/tbl_name.
#   3. sqlite3 SELECT ... WHERE <indexed col> = <v> returns the correct rows for
#      an INT-keyed and a TEXT-keyed index (covers a NULL key and duplicate keys).
#   4. sqlite3 actually PLANS to use each index (SEARCH ... USING ... INDEX idx_*).
#   5. the Medaka reader round-trips the table (it ignores the index, full-scan)
#      and does not choke on the new sqlite_master index entries.
#   6. a small committed combined-report golden.
#
# The binary .db is regenerated each run (never committed); only this script and
# the golden live in git.
#
# Usage:
#   sqlite/test/index_write_oracle.sh            # build, write db, verify
#   sqlite/test/index_write_oracle.sh --capture  # (re)write the golden
#
# Requires: sqlite3 on PATH; the Medaka tree built (`make medaka`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

GOLDEN="$HERE/index_write.golden"
DB="$(mktemp -d)/index_write.db"
OUT="$(mktemp)"

MEDAKA="$ROOT/medaka"
# Scratch binaries live in a PER-PROCESS temp dir, never at the repo root (the
# same scratch-path race the other write oracles document: `-o` is load-bearing).
BINDIR="$(mktemp -d)"
trap 'rm -rf "$BINDIR"' EXIT
WRITER="$BINDIR/sqlite_index_writer"
READER="$BINDIR/sqlite_reader"
export MEDAKA_ROOT="$ROOT"
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

# 1. Build the Medaka index-writer demo binary.
"$MEDAKA" build sqlite/index_write_demo.mdk -o "$WRITER" >/dev/null

# 2. Build the Medaka reader binary (for the self round-trip gate).
"$MEDAKA" build sqlite/main.mdk -o "$READER" >/dev/null

# 3. Generate the database WITH THE MEDAKA WRITER (from scratch — no sqlite3).
rm -f "$DB"
"$WRITER" "$DB" >/dev/null

# 4. Produce the combined report.
{
  echo "# integrity_check"
  sqlite3 "$DB" "PRAGMA integrity_check;"
  echo "# schema"
  sqlite3 "$DB" "SELECT type, name, tbl_name, rootpage FROM sqlite_master ORDER BY rootpage;"
  echo "# people"
  sqlite3 "$DB" "SELECT * FROM people ORDER BY id;"
  echo "# name index (WHERE name='bob')"
  sqlite3 "$DB" "SELECT id, name FROM people WHERE name='bob' ORDER BY name, id;"
  echo "# age index (WHERE age=25)"
  sqlite3 "$DB" "SELECT id, age FROM people WHERE age=25 ORDER BY age, id;"
  echo "# age index ordered (NULL first)"
  sqlite3 "$DB" "SELECT id, age FROM people ORDER BY age;"
  echo "# medaka reader"
  "$READER" "$DB" people
} > "$OUT"

if [ "${1:-}" = "--capture" ]; then
  cp "$OUT" "$GOLDEN"
  echo "captured golden -> $GOLDEN"
  cat "$GOLDEN"
  exit 0
fi

fail=0

# Gate 1: integrity_check ok — the decisive gate for a valid index B-tree.
echo "=== Gate 1: PRAGMA integrity_check ==="
IC="$(sqlite3 "$DB" "PRAGMA integrity_check;")"
if [ "$IC" = "ok" ]; then
  echo "OK: integrity_check = ok"
else
  echo "FAIL: integrity_check = $IC"
  fail=1
fi

# Gate 2: both indexes present in sqlite_master.
echo "=== Gate 2: sqlite_master lists both indexes ==="
NIDX="$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type='index';")"
IDXROWS="$(sqlite3 "$DB" "SELECT name || '/' || tbl_name FROM sqlite_master WHERE type='index' ORDER BY name;" | tr '\n' ' ')"
if [ "$NIDX" = "2" ] && [ "$IDXROWS" = "idx_age/people idx_name/people " ]; then
  echo "OK: 2 indexes ($IDXROWS)"
else
  echo "FAIL: nidx=$NIDX rows=$IDXROWS"
  fail=1
fi

# Gate 3: indexed-column queries return the correct rows (INT + TEXT keys,
# duplicate keys, and a NULL key via ORDER BY).
echo "=== Gate 3: indexed-column queries ==="
g3=0
diff -q <(printf '1|bob\n4|bob\n')   <(sqlite3 "$DB" "SELECT id, name FROM people WHERE name='bob' ORDER BY name, id;") >/dev/null || { echo "FAIL name index"; g3=1; }
diff -q <(printf '2|25\n5|25\n')     <(sqlite3 "$DB" "SELECT id, age FROM people WHERE age=25 ORDER BY age, id;") >/dev/null || { echo "FAIL age index"; g3=1; }
diff -q <(printf '3|\n2|25\n5|25\n1|30\n4|40\n') <(sqlite3 "$DB" "SELECT id, age FROM people ORDER BY age;") >/dev/null || { echo "FAIL age order (NULL first)"; g3=1; }
if [ "$g3" = "0" ]; then echo "OK: name/age queries correct (dup + NULL keys)"; else fail=1; fi

# Gate 4: sqlite3 actually plans to USE each index (proves the index is a real,
# usable B-tree, not just a benign sqlite_master row).
echo "=== Gate 4: sqlite3 uses each index ==="
PN="$(sqlite3 "$DB" "EXPLAIN QUERY PLAN SELECT id FROM people WHERE name='bob';")"
PA="$(sqlite3 "$DB" "EXPLAIN QUERY PLAN SELECT id FROM people WHERE age=25;")"
if echo "$PN" | grep -q "INDEX idx_name" && echo "$PA" | grep -q "INDEX idx_age"; then
  echo "OK: query planner uses idx_name and idx_age"
else
  echo "FAIL: planner did not use the indexes"
  echo "  name plan: $PN"
  echo "  age  plan: $PA"
  fail=1
fi

# Gate 5: Medaka reader round-trips the table (ignores the index) and does not
# choke on the sqlite_master index entries.
echo "=== Gate 5: Medaka reader self round-trip ==="
INTENDED="$(mktemp)"
cat > "$INTENDED" <<'EOF'
1|bob|30
2|alice|25
3|carol|
4|bob|40
5|dave|25
EOF
RD="$(mktemp)"
"$READER" "$DB" people > "$RD"
if diff -u "$INTENDED" "$RD"; then
  echo "OK: Medaka reader matches intended (reads an indexed DB)"
else
  echo "FAIL: Medaka reader differs from intended"
  fail=1
fi

# Gate 6: full combined report matches the committed golden.
echo "=== Gate 6: combined report vs committed golden ==="
if diff -u "$GOLDEN" "$OUT"; then
  echo "OK: report matches golden"
else
  echo "FAIL: report differs from golden"
  fail=1
fi

exit "$fail"
