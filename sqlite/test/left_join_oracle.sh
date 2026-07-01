#!/usr/bin/env bash
# Differential oracle for LEFT JOIN in the typed ADT query model (lib.select).
#
# Builds left_join_demo.mdk (native), runs it against a sqlite3-created
# multi-table DB seeded so SOME left rows have NO matching right row, and
# checks each labelled join block against sqlite3's own answer for the
# equivalent `SELECT ... LEFT JOIN ... ON ...` (ORDER BY a stable key).  Proves:
#   (a) unmatched left rows are kept, null-padded on the right;
#   (b) a WHERE clause touching a null-padded right column DROPS those rows,
#       matching real sqlite3 (WHERE runs post-join, three-valued NULL logic);
#   (c) a mixed 3-table INNER-then-LEFT chain null-pads only the LEFT leg.
#
# `sqlite3 -cmd ".nullvalue NULL"` renders SQL NULL as the literal text "NULL"
# (its default is empty-string) so the pipe-separated oracle output matches the
# demo's own `NULL` rendering byte-for-byte.
#
# Run from the primary checkout root.  Requires: sqlite3 on PATH, a built native
# `medaka` (./medaka) + its emitter, MEDAKA_ROOT pointing at the repo root.
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
export MEDAKA_ROOT

command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 CLI not on PATH — cannot run left join oracle"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DB="$TMP/leftjoin.db"
BIN="$TMP/ljdemo"

sqlite3 "$DB" "
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO users VALUES (1,'Alice'),(2,'Bob'),(3,'Carol'),(4,'Dave');
CREATE TABLE orders(oid INTEGER PRIMARY KEY, uid INTEGER, amount INTEGER);
INSERT INTO orders VALUES (10,1,100),(11,1,250),(12,2,175),(13,3,50);
CREATE TABLE ta(aid INTEGER PRIMARY KEY, av INTEGER);
INSERT INTO ta VALUES (1,111),(2,222);
CREATE TABLE tb(bid INTEGER PRIMARY KEY, aref INTEGER);
INSERT INTO tb VALUES (100,1),(101,2);
CREATE TABLE tc(cid INTEGER PRIMARY KEY, bref INTEGER);
INSERT INTO tc VALUES (1000,100);
"

"$MEDAKA" build --allow-internal sqlite/left_join_demo.mdk -o "$BIN" >/dev/null 2>&1 || { echo "FAIL: build"; exit 1; }

got="$("$BIN" "$DB")"

sq() { sqlite3 "$DB" -cmd ".nullvalue NULL" "$1"; }
exp=""
add() { exp+="$1"$'\n'; }
addq() { while IFS= read -r r; do exp+="$r"$'\n'; done < <(sq "$2"); }

add  "-- left join users/orders --"
addq x "SELECT users.id,users.name,orders.oid,orders.uid,orders.amount \
        FROM users LEFT JOIN orders ON users.id=orders.uid \
        ORDER BY users.id ASC, orders.oid ASC;"
add  "-- left join where amount>100 order amount --"
addq x "SELECT users.id,users.name,orders.oid,orders.uid,orders.amount \
        FROM users LEFT JOIN orders ON users.id=orders.uid \
        WHERE orders.amount>100 ORDER BY orders.amount ASC;"
add  "-- inner ta/tb then left tc --"
addq x "SELECT ta.aid,ta.av,tb.bid,tb.aref,tc.cid,tc.bref \
        FROM ta INNER JOIN tb ON ta.aid=tb.aref LEFT JOIN tc ON tb.bid=tc.bref \
        ORDER BY tb.bid ASC;"
exp="${exp%$'\n'}"

if [ "$got" = "$exp" ]; then
  echo "PASS: typed ADT LEFT JOIN output matches sqlite3"
  echo "$got"
  exit 0
else
  echo "FAIL: typed ADT LEFT JOIN output diverged from sqlite3"
  echo "--- got ---";      echo "$got"
  echo "--- expected ---"; echo "$exp"
  diff <(echo "$got") <(echo "$exp")
  exit 1
fi
