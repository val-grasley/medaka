#!/usr/bin/env bash
# Differential oracle for SELECT DISTINCT (lib.select `queryDistinct`).
#
# Builds distinct_demo.mdk (native), runs it against a sqlite3-created DB
# seeded with DUPLICATE values, and checks each labelled query block against
# sqlite3's own `SELECT DISTINCT ...` answer (ORDER BY for determinism, since
# sqlite3's DISTINCT row order is otherwise unspecified).  Proves:
#   (a) single-column DISTINCT dedups correctly;
#   (b) multi-column DISTINCT dedups on the (a,b) tuple, not per-column;
#   (c) DISTINCT + LIMIT dedups BEFORE slicing (not "take N raw rows, then
#       dedup", which would under-count).
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
DB="$TMP/dist.db"
BIN="$TMP/ddemo"

# nums: 5 rows, only 3 distinct values (1, 2, 3) — 2 is a triple-dup.
# pairs: 5 rows, only 3 distinct (a,b) tuples — proves dedup is on the TUPLE,
# not per-column (e.g. (1,1) and (1,2) share a=1 but are NOT duplicates).
sqlite3 "$DB" "CREATE TABLE nums (n INTEGER); \
  INSERT INTO nums VALUES (2),(1),(2),(3),(2); \
  CREATE TABLE pairs (a INTEGER, b INTEGER); \
  INSERT INTO pairs VALUES (1,1),(1,2),(1,1),(2,1),(1,2);"

"$MEDAKA" build sqlite/distinct_demo.mdk -o "$BIN" >/dev/null 2>&1 || { echo "FAIL: build"; exit 1; }

got="$("$BIN" "$DB")"

sq() { sqlite3 "$DB" "$1"; }

exp=""
add() { exp+="$1"$'\n'; }
addq() { while IFS= read -r r; do exp+="$r"$'\n'; done < <(sq "$2"); }

add  "-- distinct n from nums order by n --"
addq x "SELECT DISTINCT n FROM nums ORDER BY n;"
add  "-- distinct a,b from pairs order by a,b --"
addq x "SELECT DISTINCT a,b FROM pairs ORDER BY a,b;"
add  "-- distinct n from nums order by n limit 2 --"
addq x "SELECT DISTINCT n FROM nums ORDER BY n LIMIT 2;"
exp="${exp%$'\n'}"

if [ "$got" = "$exp" ]; then
  echo "PASS: DISTINCT query output matches sqlite3"
  echo "$got"
  exit 0
else
  echo "FAIL: DISTINCT query output diverged from sqlite3"
  echo "--- got ---";      echo "$got"
  echo "--- expected ---"; echo "$exp"
  diff <(echo "$got") <(echo "$exp")
  exit 1
fi
