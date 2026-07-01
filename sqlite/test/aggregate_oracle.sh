#!/usr/bin/env bash
# Differential oracle for the aggregate query model (lib.aggregate).
#
# Builds aggregate_demo.mdk (native), runs it against a sqlite3-created DB, and
# checks each labelled query block against sqlite3's own answer for the
# equivalent aggregate SELECT.  This proves the aggregate executor
# (WHERE filter → GROUP BY → reduce → HAVING → RowType decode) agrees with the
# engine across COUNT(*) / COUNT(col) with NULLs / SUM / AVG (float) / MIN / MAX /
# multi-column GROUP BY / HAVING / WHERE + GROUP / whole-table + empty-group.
#
# Run from the sqlite/ project dir.  Requires: sqlite3 on PATH, a built native
# `medaka` (../medaka) + its emitter, MEDAKA_ROOT pointing at the repo root.
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
export MEDAKA_ROOT

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DB="$TMP/emp.db"
BIN="$TMP/adem"

sqlite3 "$DB" "CREATE TABLE emp (id INTEGER PRIMARY KEY, dept TEXT, salary INTEGER, bonus REAL); \
  INSERT INTO emp VALUES (1,'eng',100,1.5),(2,'eng',250,NULL),(3,'sales',100,2.5),\
                         (4,'sales',NULL,3.0),(5,'sales',200,NULL),(6,'hr',NULL,NULL);"

"$MEDAKA" build sqlite/aggregate_demo.mdk -o "$BIN" >/dev/null 2>&1 || { echo "FAIL: build"; exit 1; }

got="$("$BIN" "$DB")"

sq() { sqlite3 "$DB" "$1"; }

exp=""
add() { exp+="$1"$'\n'; }
addq() { while IFS= read -r r; do exp+="$r"$'\n'; done < <(sq "$2"); }

add  "-- whole: count* count(sal) sum avg min max --"
addq x "SELECT count(*),count(salary),sum(salary),avg(salary),min(salary),max(salary) FROM emp;"
add  "-- group dept: count* sum(sal) --"
addq x "SELECT dept,count(*),sum(salary) FROM emp GROUP BY dept ORDER BY dept;"
add  "-- group dept: avg(sal) --"
addq x "SELECT dept,avg(salary) FROM emp GROUP BY dept ORDER BY dept;"
add  "-- group dept having count* > 1 --"
addq x "SELECT dept,count(*) FROM emp GROUP BY dept HAVING count(*)>1 ORDER BY dept;"
add  "-- group dept,salary: count* --"
addq x "SELECT dept,salary,count(*) FROM emp GROUP BY dept,salary ORDER BY dept,salary;"
add  "-- group dept: sum(bonus) [real] --"
addq x "SELECT dept,sum(bonus) FROM emp GROUP BY dept ORDER BY dept;"
add  "-- group dept: min(sal) max(sal) --"
addq x "SELECT dept,min(salary),max(salary) FROM emp GROUP BY dept ORDER BY dept;"
add  "-- where dept=sales, group dept: count* sum --"
addq x "SELECT dept,count(*),sum(salary) FROM emp WHERE dept='sales' GROUP BY dept ORDER BY dept;"
add  "-- where none, whole: count* sum(sal) --"
addq x "SELECT count(*),sum(salary) FROM emp WHERE dept='zzz';"
# The GROUP BY over an empty filtered set yields ZERO rows: label only, no data.
add  "-- where none, group dept: count* (no rows) --"
exp="${exp%$'\n'}"

if [ "$got" = "$exp" ]; then
  echo "PASS: aggregate query output matches sqlite3"
  echo "$got"
  exit 0
else
  echo "FAIL: aggregate query output diverged from sqlite3"
  echo "--- got ---";      echo "$got"
  echo "--- expected ---"; echo "$exp"
  diff <(echo "$got") <(echo "$exp")
  exit 1
fi
