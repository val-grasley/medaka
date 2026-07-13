#!/usr/bin/env bash
# Differential oracle for the UNIFIED query engine's GROUP BY / aggregate path.
#
# Builds groupby_demo.mdk (native), runs it against a sqlite3-created DB, and
# checks each labelled query block against sqlite3's own answer for the
# equivalent SQL.  Every query here was NOT REPRESENTABLE before lib.select and
# lib.aggregate were unified into one Select + one executor:
#
#   A. aggregate (count*/sum) + GROUP BY over a JOIN   — AggQuery had no joins
#   B. ORDER BY count(*) DESC LIMIT 2                  — AggQuery had no ORDER BY/LIMIT
#   C. ORDER BY on a COMPUTED (non-aggregate) column   — Select's documented v1 limitation
#   D. HAVING + ORDER BY (on a different agg) + LIMIT  — AggQuery had no ORDER BY/LIMIT
#   E. grouped MIN / MAX / AVG / SUM in one row
#   F. the GROUP BY rule: a non-aggregate projection that is not a group key is
#      REJECTED.  This one is asserted, NOT diffed: sqlite ACCEPTS it and silently
#      picks an arbitrary row from the group, and we deliberately disagree.
#
# Run from the repo root.  Requires: sqlite3 on PATH, a built native `medaka`
# (./medaka) + its emitter, MEDAKA_ROOT pointing at the repo root.
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
export MEDAKA_ROOT

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DB="$TMP/shop.db"
BIN="$TMP/gdem"

# users: dee (id 4) has NO orders — the INNER JOIN must drop her.
# orders: id 7 has a NULL amount — SUM/AVG/MIN/MAX must skip it while COUNT(*)
#         still counts the row, and `amount*qty` must be NULL for it.
sqlite3 "$DB" "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT); \
  CREATE TABLE orders (id INTEGER PRIMARY KEY, uid INTEGER, amount INTEGER, qty INTEGER); \
  INSERT INTO users VALUES (1,'ada'),(2,'bob'),(3,'cyd'),(4,'dee'); \
  INSERT INTO orders VALUES (1,1,100,2),(2,1,200,3),(3,1,300,4),\
                            (4,2,150,1),(5,2,250,3),(6,3,75,5),(7,3,NULL,2);"

"$MEDAKA" build sqlite/groupby_demo.mdk -o "$BIN" >/dev/null 2>&1 || { echo "FAIL: build"; exit 1; }

got="$("$BIN" "$DB")"

sq() { sqlite3 "$DB" "$1"; }

exp=""
add() { exp+="$1"$'\n'; }
addq() { while IFS= read -r r; do exp+="$r"$'\n'; done < <(sq "$1"); }

J="users INNER JOIN orders ON users.id = orders.uid"

add  "-- join+group name: count* sum(amount) --"
addq "SELECT users.name,count(*),sum(orders.amount) FROM $J GROUP BY users.name ORDER BY users.name ASC;"

add  "-- join+group name: order by count* desc, name asc limit 2 --"
addq "SELECT users.name,count(*) FROM $J GROUP BY users.name ORDER BY count(*) DESC, users.name ASC LIMIT 2;"

add  "-- orders: amount, qty, amount*qty order by amount*qty desc --"
addq "SELECT amount,qty,amount*qty FROM orders ORDER BY amount*qty DESC;"

add  "-- join+group name: having count*>1 order by sum(amount) asc limit 1 --"
addq "SELECT users.name,count(*),sum(orders.amount) FROM $J GROUP BY users.name HAVING count(*)>1 ORDER BY sum(orders.amount) ASC LIMIT 1;"

add  "-- group uid: min max avg sum(amount) --"
addq "SELECT uid,min(amount),max(amount),avg(amount),sum(amount) FROM orders GROUP BY uid ORDER BY uid ASC;"

# F is NOT diffed against sqlite3 (sqlite accepts it and picks an arbitrary row).
# The demo must print a query error naming the offending column.
add  "-- reject: non-aggregate column not in GROUP BY --"
add  "query error: column 'orders.amount' must appear in the GROUP BY clause or be used in an aggregate function"

exp="${exp%$'\n'}"

if [ "$got" = "$exp" ]; then
  echo "PASS: unified GROUP BY / aggregate output matches sqlite3"
  echo "$got"
  exit 0
else
  echo "FAIL: unified GROUP BY / aggregate output diverged from sqlite3"
  echo "--- got ---";      echo "$got"
  echo "--- expected ---"; echo "$exp"
  diff <(echo "$got") <(echo "$exp")
  exit 1
fi
