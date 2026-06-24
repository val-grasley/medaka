#!/usr/bin/env bash
# Differential oracle for the typed-result (RowType) query layer.
#
# Creates a DB with sqlite3, runs the typed SELECT executor (query_demo.mdk,
# compiled to native), and checks the typed-row output against sqlite3's own
# SELECT — both the full scan and an `age > 25` predicate filter.
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
BIN="$TMP/qdemo"

sqlite3 "$DB" "CREATE TABLE users (id INTEGER, name TEXT, age INTEGER); \
  INSERT INTO users VALUES (1,'Alice',30),(2,'Bob',NULL),(3,'Carol',25),(4,'Dave',40);"

"$MEDAKA" build query_demo.mdk -o "$BIN" >/dev/null 2>&1 || { echo "FAIL: build"; exit 1; }

got="$("$BIN" "$DB")"

# Expected typed output, derived from sqlite3's own answers.
# Map a sqlite3 "id|name|age" line (age may be empty=NULL) to our typed form.
typed_line() {
  local id name age
  IFS='|' read -r id name age <<<"$1"
  if [ -z "$age" ]; then
    echo "User { id=$id, name=\"$name\", age=None }"
  else
    echo "User { id=$id, name=\"$name\", age=Some $age }"
  fi
}

exp="-- fetchAll users --"
while IFS= read -r row; do exp+=$'\n'"$(typed_line "$row")"; done \
  < <(sqlite3 "$DB" "SELECT id,name,age FROM users ORDER BY id;")
exp+=$'\n'"-- scanTable users WHERE age > 25 --"
while IFS= read -r row; do exp+=$'\n'"$(typed_line "$row")"; done \
  < <(sqlite3 "$DB" "SELECT id,name,age FROM users WHERE age > 25 ORDER BY id;")

if [ "$got" = "$exp" ]; then
  echo "PASS: typed query output matches sqlite3"
  echo "$got"
  exit 0
else
  echo "FAIL: typed query output diverged from sqlite3"
  echo "--- got ---";      echo "$got"
  echo "--- expected ---"; echo "$exp"
  diff <(echo "$got") <(echo "$exp")
  exit 1
fi
