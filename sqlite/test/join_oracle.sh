#!/usr/bin/env bash
# Differential oracle for INNER JOIN in the typed ADT query model (lib.select).
#
# Builds join_demo.mdk (native), runs it against a sqlite3-created multi-table DB,
# and checks each labelled join block against sqlite3's own answer for the
# equivalent SELECT ... INNER JOIN ... ON ... (ORDER BY a stable key).  This
# proves the join executor (nested-loop + combined lookup over qualified column
# names + ON predicate + WHERE + ORDER BY over the wide row) agrees with the
# engine for 2-table and 3-table equi-joins, with and without a WHERE filter.
#
# Run from the primary checkout root.  Requires: sqlite3 on PATH, a built native
# `medaka` (./medaka) + its emitter, MEDAKA_ROOT pointing at the repo root.
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
export MEDAKA_ROOT

command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 CLI not on PATH — cannot run join oracle"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DB="$TMP/join.db"
BIN="$TMP/jdemo"

sqlite3 "$DB" "
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO users VALUES (1,'Alice'),(2,'Bob'),(3,'Carol');
CREATE TABLE orders(oid INTEGER PRIMARY KEY, uid INTEGER, amount INTEGER);
INSERT INTO orders VALUES (10,1,100),(11,1,250),(12,2,175),(13,3,50),(14,99,999);
CREATE TABLE ta(aid INTEGER PRIMARY KEY, av INTEGER);
INSERT INTO ta VALUES (1,111),(2,222);
CREATE TABLE tb(bid INTEGER PRIMARY KEY, aref INTEGER);
INSERT INTO tb VALUES (100,1),(101,2),(102,1);
CREATE TABLE tc(cid INTEGER PRIMARY KEY, bref INTEGER);
INSERT INTO tc VALUES (1000,100),(1001,102),(1002,101),(1003,999);
"

"$MEDAKA" build sqlite/join_demo.mdk -o "$BIN" >/dev/null 2>&1 || { echo "FAIL: build"; exit 1; }

got="$("$BIN" "$DB")"

sq() { sqlite3 "$DB" "$1"; }
exp=""
add() { exp+="$1"$'\n'; }
addq() { while IFS= read -r r; do exp+="$r"$'\n'; done < <(sq "$2"); }

add  "-- join users/orders --"
addq x "SELECT users.id,users.name,orders.oid,orders.uid,orders.amount \
        FROM users INNER JOIN orders ON users.id=orders.uid ORDER BY orders.oid ASC;"
add  "-- join users/orders where amount>100 --"
addq x "SELECT users.id,users.name,orders.oid,orders.uid,orders.amount \
        FROM users INNER JOIN orders ON users.id=orders.uid WHERE orders.amount>100 ORDER BY orders.amount ASC;"
add  "-- join users/orders where users.id=1 --"
addq x "SELECT users.id,users.name,orders.oid,orders.uid,orders.amount \
        FROM users INNER JOIN orders ON users.id=orders.uid WHERE users.id=1 ORDER BY orders.amount DESC;"
add  "-- join ta/tb/tc --"
addq x "SELECT ta.aid,ta.av,tb.bid,tb.aref,tc.cid,tc.bref \
        FROM ta INNER JOIN tb ON ta.aid=tb.aref INNER JOIN tc ON tb.bid=tc.bref ORDER BY tc.cid ASC;"
exp="${exp%$'\n'}"

if [ "$got" = "$exp" ]; then
  echo "PASS: typed ADT INNER JOIN output matches sqlite3"
  echo "$got"
  exit 0
else
  echo "FAIL: typed ADT INNER JOIN output diverged from sqlite3"
  echo "--- got ---";      echo "$got"
  echo "--- expected ---"; echo "$exp"
  diff <(echo "$got") <(echo "$exp")
  exit 1
fi
