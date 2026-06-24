#!/usr/bin/env bash
# Differential oracle for the typed ADT query model (lib.select).
#
# Builds select_demo.mdk (native), runs it against a sqlite3-created DB, and
# checks each labelled query block against sqlite3's own answer for the
# equivalent SELECT (ORDER BY rowid for determinism).  This proves the ADT
# query executor (compilePred + scan + offset/limit + RowType decode) agrees
# with the engine across comparison / AND / OR / IS NULL / IS NOT NULL /
# LIMIT / OFFSET.
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
DB="$TMP/users.db"
BIN="$TMP/sdemo"

sqlite3 "$DB" "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER); \
  INSERT INTO users VALUES (1,'Alice',30),(2,'Bob',NULL),(3,'Carol',25),(4,'Dave',40),(5,'Eve',22);"

"$MEDAKA" build sqlite/select_demo.mdk -o "$BIN" >/dev/null 2>&1 || { echo "FAIL: build"; exit 1; }

got="$("$BIN" "$DB")"

# Map a sqlite3 "id|name|age" line (age may be empty=NULL) to the demo's form
# (which is identical — id|name|age, NULL age = empty).  The demo prints exactly
# the pipe-joined columns, so sqlite3's output IS the expected form.
sq() { sqlite3 "$DB" "$1"; }

exp=""
add() { exp+="$1"$'\n'; }
addq() { while IFS= read -r r; do exp+="$r"$'\n'; done < <(sq "$2"); }

add  "-- age > 25 --";                addq x "SELECT id,name,age FROM users WHERE age > 25 ORDER BY rowid;"
add  "-- age > 20 AND age < 40 --";   addq x "SELECT id,name,age FROM users WHERE age > 20 AND age < 40 ORDER BY rowid;"
add  "-- name = Bob OR age = 40 --";  addq x "SELECT id,name,age FROM users WHERE name='Bob' OR age = 40 ORDER BY rowid;"
add  "-- age IS NULL --";             addq x "SELECT id,name,age FROM users WHERE age IS NULL ORDER BY rowid;"
add  "-- age IS NOT NULL --";         addq x "SELECT id,name,age FROM users WHERE age IS NOT NULL ORDER BY rowid;"
add  "-- limit 2 --";                 addq x "SELECT id,name,age FROM users ORDER BY rowid LIMIT 2;"
add  "-- limit 2 offset 1 --";        addq x "SELECT id,name,age FROM users ORDER BY rowid LIMIT 2 OFFSET 1;"
add  "-- age > 25 limit 1 --";        addq x "SELECT id,name,age FROM users WHERE age > 25 ORDER BY rowid LIMIT 1;"
exp="${exp%$'\n'}"

if [ "$got" = "$exp" ]; then
  echo "PASS: typed ADT query output matches sqlite3"
  echo "$got"
  exit 0
else
  echo "FAIL: typed ADT query output diverged from sqlite3"
  echo "--- got ---";      echo "$got"
  echo "--- expected ---"; echo "$exp"
  diff <(echo "$got") <(echo "$exp")
  exit 1
fi
