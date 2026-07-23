#!/usr/bin/env bash
# Differential oracle for the DML/DDL statements + the SQL CLI (lib.sqlstmt's
# `Stmt` grammar, lib.schemadef, lib.mutate's write engine, lib.sqlexec).
#
# The shape of the gate: the SAME SQL TEXT is executed by BOTH engines —
#
#   (a) the real `sqlite3` CLI, against `s.db`
#   (b) the Medaka CLI (`sqlite/main.mdk`, a NATIVE binary), against `m.db`
#
# — starting from identical (empty, or sqlite3-authored) databases, and then the
# resulting FILES are compared by asking `sqlite3` to read both back.  Comparing
# through sqlite3 is the point: it means the assertion is "sqlite3 sees the same
# database", not "Medaka reproduces its own bug in both directions".  Storage
# class is compared too (`typeof`), because storing the TEXT '5' where sqlite3
# stores the INTEGER 5 is a silent wrong answer that a value-only diff misses.
#
# An interpreter-green result proves NOTHING here: the known
# partially-applied-constructor miscompile is invisible to a doctest and shows up
# only in a native binary.  Every section below runs the BUILT binary.
#
# Sections:
#   1. DML CORPUS    — CREATE/INSERT/UPDATE/DELETE replayed on both engines from an
#                      empty database; every table then diffed through sqlite3
#                      (values + typeof + hex of blobs), plus PRAGMA integrity_check.
#   2. AUTHORED DB   — a database CREATEd and populated by sqlite3, then mutated by
#                      the Medaka CLI; same comparison.
#   3. OVERFLOW      — a multi-KB TEXT value INSERTed and UPDATEd through the DML
#                      path (overflow pages), content compared with hex().
#   4. CLI SELECT    — the Medaka CLI's stdout must be BYTE-IDENTICAL to
#                      `sqlite3 db "<same SQL>"` for a corpus of SELECTs.
#   5. REJECTIONS    — every unsupported construct and every constraint violation
#                      must print a clean `error: …` and exit 0 — never a panic,
#                      never a partial write (the database must still be valid and
#                      UNCHANGED afterwards).
#   6. PARSE PROBE   — sqlite/dml_probe.mdk (render corpus + reject corpus), run as
#                      a NATIVE binary.
#
# Run from the repo root.  Requires: sqlite3 on PATH, a built native `medaka`
# (./medaka) + its emitter, MEDAKA_ROOT pointing at the repo root.
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
export MEDAKA_ROOT
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CLI="$TMP/sqlcli"
PROBE="$TMP/dmlprobe"

"$MEDAKA" build sqlite/main.mdk -o "$CLI" >"$TMP/build.err" 2>&1 || {
  echo "FAIL: build sqlite/main.mdk"; cat "$TMP/build.err"; exit 1; }
"$MEDAKA" build sqlite/dml_probe.mdk -o "$PROBE" >"$TMP/pbuild.err" 2>&1 || {
  echo "FAIL: build sqlite/dml_probe.mdk"; cat "$TMP/pbuild.err"; exit 1; }

fail=0
note() { echo "  $*"; }

# ── helpers ──────────────────────────────────────────────────────────────────

# Ask sqlite3 to dump one table of a database completely: rowid, every column's
# VALUE, every column's TYPEOF, and hex() of anything blob-shaped.  Columns are
# discovered from the db itself so the dump adapts to the schema.
dump_table() {
  local db="$1" tbl="$2"
  local cols
  cols="$(sqlite3 "$db" "SELECT group_concat('typeof(\"' || name || '\"), hex(\"' || name || '\")', ', ') FROM pragma_table_info('$tbl');")"
  sqlite3 "$db" "SELECT rowid, $cols FROM \"$tbl\" ORDER BY rowid;"
}

# Dump the whole database: the schema (name + sql), then every table's contents.
dump_db() {
  local db="$1"
  sqlite3 "$db" "SELECT type, name FROM sqlite_master ORDER BY name;"
  for t in $(sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"); do
    echo "# table $t"
    dump_table "$db" "$t"
  done
}

# Compare two databases through sqlite3; also assert the Medaka-written one is
# structurally valid.
compare_dbs() {
  local label="$1" mdb="$2" sdb="$3"
  local ic
  ic="$(sqlite3 "$mdb" "PRAGMA integrity_check;")"
  if [ "$ic" != "ok" ]; then
    fail=$((fail + 1)); echo "FAIL [$label]: PRAGMA integrity_check = $ic"; return
  fi
  if diff -u <(dump_db "$mdb") <(dump_db "$sdb") >"$TMP/d.txt"; then
    echo "ok   [$label]: integrity_check=ok, and sqlite3 reads both databases identically"
  else
    fail=$((fail + 1))
    echo "FAIL [$label]: the two databases differ"
    sed 's/^/    /' "$TMP/d.txt"
  fi
}

# Run one statement through BOTH engines, asserting both succeed.
both() {
  local mdb="$1" sdb="$2" sql="$3"
  local mout serr
  mout="$("$CLI" "$mdb" "$sql" 2>&1)"
  case "$mout" in
    error:*|Error:*)
      fail=$((fail + 1)); echo "FAIL: Medaka refused a supported statement: $sql"; note "$mout" ;;
  esac
  serr="$(sqlite3 "$sdb" "$sql" 2>&1)"
  case "$serr" in
    Error*|Parse\ error*)
      fail=$((fail + 1)); echo "FAIL: sqlite3 refused the corpus statement: $sql"; note "$serr" ;;
  esac
}

# ── 1. DML CORPUS ────────────────────────────────────────────────────────────
# Both databases start EMPTY (no file at all): the first CREATE TABLE has to
# create the file, which is exactly what the `medaka build`-produced CLI must do.
M1="$TMP/m1.db"; S1="$TMP/s1.db"

CORPUS=(
  # -- CREATE: IPK, NOT NULL, every affinity, a typeless column, a sized type ---
  "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER, score REAL)"
  "CREATE TABLE kv (k TEXT, b BLOB, note VARCHAR(20))"
  "CREATE TABLE bare (a, n INTEGER)"
  "CREATE TABLE aff (id INTEGER PRIMARY KEY, i INTEGER, r REAL, t TEXT, b BLOB)"
  # -- INSERT: positional, no column list ---------------------------------------
  "INSERT INTO users VALUES (1, 'ada', 30, 9.5)"
  "INSERT INTO users VALUES (2, 'bob', NULL, NULL)"
  # -- INSERT: multi-row VALUES --------------------------------------------------
  "INSERT INTO users VALUES (10, 'cyd', 24, 1.0), (11, 'dee', 40, 2.5), (12, 'eve', -3, -0.25)"
  # -- INSERT: with a column list; omitted columns become NULL --------------------
  "INSERT INTO users (name, age) VALUES ('fay', 19)"
  "INSERT INTO users (age, name) VALUES (55, 'gus')"
  # -- INSERT: explicit NULL IPK ⇒ auto rowid ------------------------------------
  "INSERT INTO users (id, name) VALUES (NULL, 'hal')"
  # -- INSERT: an explicit IPK BELOW the existing max (row must sort into place) --
  "INSERT INTO users VALUES (3, 'ivy', 66, 0.0)"
  # -- INSERT: constant-folded VALUES expression ---------------------------------
  "INSERT INTO users (id, name, age) VALUES (2 * 10 + 1, 'jan', 7 - 2)"
  # -- INSERT: type AFFINITY.  Every cell here is a value whose STORAGE CLASS
  #    sqlite3 changes on the way in ('5' into an INTEGER column becomes the
  #    integer 5, 3 into a REAL column becomes 3.0, 1.5 into a TEXT column becomes
  #    '1.5', and 'abc' into an INTEGER column stays text).  `dump_table` compares
  #    typeof() as well as the value, so a missed coercion FAILS here.
  #    Held in its own table because the arithmetic UPDATEs below would otherwise
  #    trip a SEPARATE, pre-existing `lib.select` bug (arithmetic on a TEXT operand
  #    yields NULL where sqlite3 coerces the text to 0) — see
  #    findings/sql-dml-cli.md D1.  That bug is in the query engine, not the DML
  #    path, so it is reported rather than smuggled into this corpus.
  "INSERT INTO aff VALUES (1, '5', '2.5', 1, '7')"
  "INSERT INTO aff VALUES (2, '1.5', 3, 2.5, X'41')"
  "INSERT INTO aff VALUES (3, 'abc', 'zz', NULL, 9)"
  "INSERT INTO aff VALUES (4, 2.0, '1e3', '3', NULL)"
  "INSERT INTO aff (id, i, r, t) VALUES (5, '  7 ', '.5', 1.5)"
  "INSERT INTO aff (id, i) VALUES (6, '0012')"
  # -- INSERT: BLOB, quoted quote, empty string ----------------------------------
  "INSERT INTO kv VALUES ('a', X'004142FF', 'plain')"
  "INSERT INTO kv VALUES ('it''s', NULL, '')"
  "INSERT INTO kv (k) VALUES ('only-k')"
  # -- INSERT into a table with NO primary key (rowid auto-assigns) --------------
  "INSERT INTO bare VALUES ('x', 1), ('y', 2)"
  "INSERT INTO bare (n) VALUES (3)"
  # -- UPDATE: constant, expression RHS, NULL, WHERE, no WHERE -------------------
  "UPDATE users SET age = age + 1 WHERE id > 10"
  "UPDATE users SET score = score * 2, name = 'DEE' WHERE id = 11"
  "UPDATE users SET score = NULL WHERE age IS NULL"
  "UPDATE bare SET n = n * 10"
  "UPDATE users SET age = '77' WHERE id = 1"
  "UPDATE aff SET t = 42, r = 8 WHERE id = 6"
  "UPDATE kv SET b = X'4243' WHERE k = 'only-k'"
  # -- DELETE: predicate, three-valued logic, no WHERE on one table --------------
  "DELETE FROM users WHERE age IS NULL"
  "DELETE FROM users WHERE NOT score > 0.0"
  "DELETE FROM kv WHERE k = 'nosuch'"
)

for sql in "${CORPUS[@]}"; do
  both "$M1" "$S1" "$sql"
done
compare_dbs "dml corpus" "$M1" "$S1"

# ── 2. AUTHORED DB: sqlite3 writes it, Medaka mutates it ─────────────────────
M2="$TMP/m2.db"; S2="$TMP/s2.db"
sqlite3 "$M2" "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, city TEXT);
  CREATE TABLE orders (oid INTEGER PRIMARY KEY, uid INTEGER, amt INTEGER);
  INSERT INTO users VALUES (1,'ada','pdx'),(2,'bob','nyc'),(3,'cyd',NULL);
  INSERT INTO orders VALUES (1,1,100),(2,2,200),(3,1,50);"
cp "$M2" "$S2"

AUTHORED=(
  "INSERT INTO users VALUES (4, 'dee', 'sea')"
  "INSERT INTO orders (uid, amt) VALUES (4, 999)"
  "UPDATE orders SET amt = amt * 2 WHERE uid = 1"
  "DELETE FROM users WHERE city IS NULL"
  "CREATE TABLE tags (t TEXT NOT NULL)"
  "INSERT INTO tags VALUES ('new')"
)
for sql in "${AUTHORED[@]}"; do
  both "$M2" "$S2" "$sql"
done
compare_dbs "sqlite3-authored db, Medaka-mutated" "$M2" "$S2"

# ── 3. OVERFLOW: a multi-KB value through the DML path ───────────────────────
M3="$TMP/m3.db"; S3="$TMP/s3.db"
BIG="$(python3 -c "print('x' * 5000)")"
BIG2="$(python3 -c "print('y' * 9000)")"
OVERFLOW=(
  "CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT NOT NULL, n INTEGER)"
  "INSERT INTO docs VALUES (1, '$BIG', 1)"
  "INSERT INTO docs VALUES (2, 'small', 2)"
  "UPDATE docs SET body = '$BIG2' WHERE id = 2"
  "INSERT INTO docs (body) VALUES ('$BIG')"
  "DELETE FROM docs WHERE id = 1"
)
for sql in "${OVERFLOW[@]}"; do
  both "$M3" "$S3" "$sql"
done
compare_dbs "multi-KB overflow rows through DML" "$M3" "$S3"
lens="$(sqlite3 "$M3" "SELECT length(body) FROM docs ORDER BY rowid;" | tr '\n' ',')"
if [ "$lens" = "9000,5000," ]; then
  echo "ok   [overflow]: the surviving bodies really are 9000 and 5000 bytes"
else
  fail=$((fail + 1)); echo "FAIL [overflow]: expected bodies 9000,5000 — got $lens"
fi

# ── 4. CLI SELECT: byte-identical to the sqlite3 CLI ─────────────────────────
# Run against the corpus database from section 1 (Medaka's copy) and sqlite3's
# copy.  They were already proven identical above, so any diff here is a
# RENDERING difference in the CLI, which is exactly what this section gates.
SELECTS=(
  "SELECT * FROM users ORDER BY id"
  "SELECT id, name, age, score FROM users ORDER BY id"
  "SELECT name FROM users WHERE age > 20 ORDER BY name"
  "SELECT name, age FROM users WHERE score IS NULL ORDER BY id"
  "SELECT count(*), sum(age), min(age), max(age) FROM users"
  "SELECT age, count(*) FROM users GROUP BY age HAVING count(*) >= 1 ORDER BY age"
  "SELECT DISTINCT age FROM users ORDER BY age"
  "SELECT id, age * 2, score + 0.5 FROM users ORDER BY id LIMIT 3"
  "SELECT id, name FROM users ORDER BY id DESC LIMIT 2 OFFSET 1"
  "select k, note from kv order by k"
  "SELECT * FROM bare ORDER BY n"
  "SELECT a, n FROM bare WHERE n IS NOT NULL ORDER BY n"
  "SELECT users.name, users.age FROM users INNER JOIN bare ON users.age = bare.n ORDER BY users.id"
  "SELECT id, i, r, t FROM aff ORDER BY id"
  "SELECT id FROM aff WHERE i = 5"
)
cpass=0
for q in "${SELECTS[@]}"; do
  got="$("$CLI" "$M1" "$q" 2>&1)"
  want="$(sqlite3 "$S1" "$q" 2>&1)"
  if [ "$got" = "$want" ]; then
    cpass=$((cpass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL [cli select]: $q"
    diff <(printf '%s\n' "$got") <(printf '%s\n' "$want") | sed 's/^/    /'
  fi
done
echo "ok   [cli select]: $cpass/${#SELECTS[@]} SELECTs byte-identical to the sqlite3 CLI"

# ── 5. REJECTIONS ────────────────────────────────────────────────────────────
# Every one of these must print a clean `error: …` and exit 0, and must leave the
# database BYTE-UNCHANGED (no partial write).  sqlite3 accepts several of them —
# we refuse on purpose, which is the whole point of the section.
M5="$TMP/m5.db"
sqlite3 "$M5" "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL, n INTEGER);
  INSERT INTO t VALUES (1,'a',10),(2,'b',20);"
BEFORE="$(md5sum <"$M5")"

REJECTS=(
  # constraint violations
  "INSERT INTO t VALUES (1, 'dup', 1)"                      # duplicate rowid
  "INSERT INTO t (id, name) VALUES (2, 'dup')"              # duplicate rowid, named
  "INSERT INTO t (n) VALUES (5)"                            # NOT NULL name omitted
  "INSERT INTO t VALUES (3, NULL, 1)"                       # NOT NULL explicit
  "INSERT INTO t (id, name) VALUES ('abc', 'x')"            # non-integer IPK
  "UPDATE t SET name = NULL WHERE id = 1"                   # NOT NULL via UPDATE
  "UPDATE t SET id = 9 WHERE id = 1"                        # moving the rowid
  # arity / naming
  "INSERT INTO t VALUES (3, 'c')"                           # too few values
  "INSERT INTO t VALUES (3, 'c', 1, 2)"                     # too many values
  "INSERT INTO t (id, name) VALUES (3)"                     # column/value mismatch
  "INSERT INTO t (nosuch) VALUES (1)"                       # unknown column
  "INSERT INTO t (id, id) VALUES (3, 4)"                    # duplicate column
  "INSERT INTO nosuch VALUES (1)"                           # unknown table
  "UPDATE t SET nosuch = 1"                                 # unknown SET column
  "UPDATE nosuch SET n = 1"                                 # unknown table
  "DELETE FROM nosuch"                                      # unknown table
  "DELETE FROM t WHERE nosuch = 1"                          # unknown WHERE column
  "INSERT INTO t VALUES (3, name, 1)"                       # column ref in VALUES
  "CREATE TABLE t (a INTEGER)"                              # table already exists
  # unsupported statements / clauses
  "DROP TABLE t"
  "ALTER TABLE t ADD COLUMN x INTEGER"
  "CREATE INDEX i ON t(name)"
  "CREATE TABLE u (a INTEGER) WITHOUT ROWID"
  "CREATE TABLE u (k TEXT PRIMARY KEY)"
  "CREATE TABLE u (a INTEGER DEFAULT 1)"
  "CREATE TABLE u (a INTEGER, UNIQUE(a))"
  "INSERT INTO t SELECT * FROM t"
  "INSERT OR REPLACE INTO t VALUES (1, 'x', 1)"
  "UPDATE t SET n = 1 LIMIT 1"
  "DELETE FROM t ORDER BY id"
  "TRUNCATE t"
  "SELEC * FROM t"
  # an IN (SELECT …) subquery in an UPDATE/DELETE WHERE: the expression grammar is
  # shared with SELECT so it PARSES, but only the SELECT pipeline materializes a
  # subquery — mutate refuses it with a clean message and no partial write, rather
  # than reaching compileTri's internal-error arm.
  "UPDATE t SET n = 0 WHERE id IN (SELECT id FROM t)"
  "DELETE FROM t WHERE id NOT IN (SELECT id FROM t)"
)
rpass=0
for q in "${REJECTS[@]}"; do
  out="$("$CLI" "$M5" "$q" 2>&1)"; st=$?
  case "$out" in
    error:*)
      if [ "$st" -eq 0 ]; then rpass=$((rpass + 1))
      else fail=$((fail + 1)); echo "FAIL [reject]: exit $st (not a clean error) for: $q"; fi
      ;;
    *)
      fail=$((fail + 1))
      echo "FAIL [reject]: NOT REJECTED: $q"
      note "got: $out"
      ;;
  esac
done
AFTER="$(md5sum <"$M5")"
if [ "$BEFORE" = "$AFTER" ]; then
  echo "ok   [reject]: $rpass/${#REJECTS[@]} clean errors, and the database is byte-unchanged"
else
  fail=$((fail + 1))
  echo "FAIL [reject]: a refused statement MODIFIED the database (partial write)"
fi
ic5="$(sqlite3 "$M5" "PRAGMA integrity_check;")"
[ "$ic5" = "ok" ] || { fail=$((fail + 1)); echo "FAIL [reject]: integrity_check after rejections = $ic5"; }

# A database sqlite3 wrote with constructs we cannot round-trip must be REFUSED,
# not silently rewritten without them.
M6="$TMP/m6.db"
sqlite3 "$M6" "CREATE TABLE t (id integer primary key, v TEXT); INSERT INTO t VALUES (1,'a');"
out="$("$CLI" "$M6" "INSERT INTO t VALUES (2, 'b')" 2>&1)"
case "$out" in
  error:*) echo "ok   [reject]: a lowercase 'integer primary key' schema (which the reader's case-sensitive IPK scan would MISS) is refused, not corrupted" ;;
  *) fail=$((fail + 1)); echo "FAIL [reject]: lowercase IPK schema was written to: $out" ;;
esac

M7="$TMP/m7.db"
sqlite3 "$M7" "CREATE TABLE t (a INTEGER, b TEXT); CREATE INDEX ib ON t(b); INSERT INTO t VALUES (1,'x');"
out="$("$CLI" "$M7" "INSERT INTO t VALUES (2, 'y')" 2>&1)"
case "$out" in
  error:*) echo "ok   [reject]: a database with a secondary index is refused (the rewrite would silently drop it)" ;;
  *) fail=$((fail + 1)); echo "FAIL [reject]: indexed database was written to: $out" ;;
esac

# ── 6. PARSE PROBE (native binary) ───────────────────────────────────────────
probe_out="$("$PROBE")"
case "$probe_out" in
  *"TOTAL: PASS") echo "ok   [parse probe]: $(printf '%s' "$probe_out" | head -2 | tr '\n' ' ')" ;;
  *) fail=$((fail + 1)); echo "FAIL [parse probe]:"; printf '%s\n' "$probe_out" | sed 's/^/    /' ;;
esac

# ── verdict ──────────────────────────────────────────────────────────────────
echo
if [ "$fail" -eq 0 ]; then
  echo "PASS: DML/DDL statements + the SQL CLI agree with sqlite3; every unsupported construct and every constraint violation is a clean Err with no write"
  exit 0
else
  echo "FAIL: $fail DML oracle assertion(s) failed"
  exit 1
fi
