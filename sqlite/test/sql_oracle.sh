#!/usr/bin/env bash
# Differential oracle for the SQL STATEMENT parser (lib.sqlstmt) + the unified
# query engine, driven from SQL TEXT.
#
# This is the strongest differential this library has: for every SQL string in
# the corpus below, the SAME TEXT is fed to BOTH engines —
#
#   (a) the real `sqlite3` CLI  (default -list output: `|`-joined, NULL = "")
#   (b) `sqlite/sql_demo.mdk`, a native Medaka binary doing
#       parseSelect → query → render the cells in the same -list form
#
# — and their row output is diffed. One input language, two implementations. The
# earlier oracles (select/join/groupby/...) each built a `Select` ADT BY HAND in
# Medaka and diffed it against a hand-written equivalent SQL string; the SQL text
# and the ADT could drift apart and no test would notice. Here the SQL text IS
# the input to both sides, so the parser is under test too.
#
# Three sections:
#   1. QUERY CORPUS  — diffed row-for-row against sqlite3.
#   2. REJECTION CORPUS — SQL we deliberately do NOT support. Asserted to produce
#      a clean `error: ...` (never a wrong answer, never a panic). NOT diffed:
#      sqlite3 happily executes most of these, and we refuse ON PURPOSE.
#   3. ROUND TRIP — parseSelect → renderSelect → parseSelect is the identity on
#      `Select`, checked over the query corpus by sqlite/sql_probe.mdk.
#
# Run from the repo root. Requires: sqlite3 on PATH, a built native `medaka`
# (./medaka) + its emitter, MEDAKA_ROOT pointing at the repo root.
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
export MEDAKA_ROOT

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DB="$TMP/shop.db"
BIN="$TMP/sqldem"
PROBE="$TMP/sqlprobe"

# users:  dee (id 4) has NO orders — an INNER JOIN drops her, a LEFT JOIN keeps
#         her null-padded.  bob (id 2) has a NULL age (the three-valued-logic
#         probe: `NOT age = 30` must DROP him, not keep him).  ada and dee share
#         age 30 (a DISTINCT / GROUP BY duplicate, and an ORDER BY tie).
# orders: id 5 has a NULL amount — SUM/AVG/MIN/MAX skip it, COUNT(*) still counts
#         the row, and `amount * qty` is NULL for it.
#
# ⚠️ The numbers are chosen so every avg() is EXACT (28.0, 200.0, 150.0, 75.0,
# 165.0).  Not cosmetic: for an INEXACT float the two engines print DIFFERENT text —
# Medaka's `floatToString` emits shortest-round-trip (issue #57, e.g. `28.333333333333332`)
# while sqlite3 emits `%.15g` (`28.3333333333333`) — even though both denote the SAME
# IEEE double, so a byte-diff would spuriously fail.  Those inexact cases are pulled out
# into the FLOAT ROUND-TRIP section below, which asserts same-double (not byte-equality).
# See findings/sql-parser-select.md F3.
sqlite3 "$DB" "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, city TEXT); \
  CREATE TABLE orders (id INTEGER PRIMARY KEY, uid INTEGER, amount INTEGER, qty INTEGER); \
  INSERT INTO users VALUES (1,'ada',30,'pdx'),(2,'bob',NULL,'nyc'),(3,'cyd',24,'pdx'),(4,'dee',30,NULL); \
  INSERT INTO orders VALUES (1,1,100,2),(2,1,200,3),(3,2,150,1),(4,3,75,5),(5,3,NULL,2),(6,1,300,1);"

"$MEDAKA" build sqlite/sql_demo.mdk -o "$BIN" >"$TMP/build.err" 2>&1 || {
  echo "FAIL: build sql_demo"; cat "$TMP/build.err"; exit 1; }
"$MEDAKA" build sqlite/sql_probe.mdk -o "$PROBE" >"$TMP/pbuild.err" 2>&1 || {
  echo "FAIL: build sql_probe"; cat "$TMP/pbuild.err"; exit 1; }

# ── 1. QUERY CORPUS ───────────────────────────────────────────────────────────
# Every query has a deterministic row order (an ORDER BY, or a single row), so a
# byte diff is meaningful.  The corpus is a bash array of SQL strings; each is fed
# VERBATIM to both engines.
QUERIES=(
  # -- plain SELECT / WHERE ---------------------------------------------------
  "SELECT id, name, age FROM users ORDER BY id"
  "SELECT name FROM users WHERE age > 25 ORDER BY name"
  "SELECT name, age FROM users WHERE age > 20 AND age < 30 ORDER BY id"
  "SELECT name FROM users WHERE name = 'bob' OR age = 24 ORDER BY id"
  "SELECT name, city FROM users WHERE city = 'pdx' ORDER BY name"
  # -- NOT over a NULLable column: SQL THREE-VALUED logic ----------------------
  # bob's age is NULL.  `NOT (NULL = 30)` is UNKNOWN, not TRUE, so bob is DROPPED.
  # Collapsing UNKNOWN to FALSE before the NOT (what the engine used to do) keeps
  # him — a silent wrong answer that this oracle is what caught.
  "SELECT name FROM users WHERE NOT age = 30 ORDER BY id"
  "SELECT name FROM users WHERE NOT (age = 30 AND name = 'ada') ORDER BY id"
  "SELECT name FROM users WHERE NOT age > 25 ORDER BY id"
  "SELECT name FROM users WHERE NOT age IS NULL ORDER BY id"
  "SELECT name FROM users WHERE NOT age IS NOT NULL ORDER BY id"
  "SELECT id FROM orders WHERE NOT amount > 100 ORDER BY id"
  "SELECT id FROM orders WHERE NOT (amount > 100 OR qty = 5) ORDER BY id"
  "SELECT name FROM users WHERE age = 30 OR NOT age = 30 ORDER BY id"
  # -- SELECT * ---------------------------------------------------------------
  "SELECT * FROM users ORDER BY id"
  "SELECT * FROM orders WHERE amount >= 100 ORDER BY id"
  "select * from users where age is null"
  # -- projection + arithmetic ------------------------------------------------
  "SELECT amount, qty, amount * qty FROM orders ORDER BY id"
  "SELECT amount + 1, amount - 1, amount * 2, amount / 3, amount % 7 FROM orders WHERE id = 2"
  "SELECT name, age + 5 FROM users WHERE age IS NOT NULL ORDER BY name"
  "SELECT id, -amount FROM orders WHERE amount IS NOT NULL ORDER BY id"
  "SELECT (amount + qty) * 2 FROM orders WHERE id = 1"
  "SELECT amount * 1.5 FROM orders WHERE id = 1"
  # -- DISTINCT ---------------------------------------------------------------
  "SELECT DISTINCT age FROM users ORDER BY age"
  "SELECT DISTINCT city FROM users ORDER BY city"
  "SELECT DISTINCT uid FROM orders ORDER BY uid"
  "SELECT DISTINCT age FROM users WHERE age IS NOT NULL ORDER BY age DESC"
  "SELECT DISTINCT uid FROM orders ORDER BY uid LIMIT 2"
  # -- INNER JOIN (qualified t.col) -------------------------------------------
  "SELECT users.name, orders.amount FROM users INNER JOIN orders ON users.id = orders.uid ORDER BY orders.id"
  "SELECT users.name, orders.amount FROM users JOIN orders ON users.id = orders.uid WHERE orders.amount > 100 ORDER BY orders.id"
  "SELECT users.name, orders.amount * orders.qty FROM users INNER JOIN orders ON users.id = orders.uid ORDER BY orders.id"
  # -- LEFT JOIN (dee has no orders → null-padded) ----------------------------
  "SELECT users.name, orders.amount FROM users LEFT JOIN orders ON users.id = orders.uid ORDER BY users.id, orders.id"
  "SELECT users.name, orders.id FROM users LEFT OUTER JOIN orders ON users.id = orders.uid ORDER BY users.id, orders.id"
  "SELECT users.name FROM users LEFT JOIN orders ON users.id = orders.uid WHERE orders.id IS NULL"
  # -- AS aliases: table alias (FROM + JOIN, AS + bare + implicit), column alias -
  "SELECT u.name, u.age FROM users u WHERE u.age > 25 ORDER BY u.id"
  "SELECT u.name, u.city FROM users AS u WHERE u.city = 'pdx' ORDER BY u.id"
  "SELECT name AS who, age AS years FROM users WHERE age IS NOT NULL ORDER BY id"
  "SELECT id, age + 1 AS next FROM users WHERE age IS NOT NULL ORDER BY id"
  "SELECT * FROM users u ORDER BY u.id"
  "SELECT u.name, o.amount FROM users u INNER JOIN orders o ON u.id = o.uid ORDER BY o.id"
  "SELECT u.name AS who, o.amount AS amt FROM users u JOIN orders o ON u.id = o.uid ORDER BY o.id"
  "SELECT u.name, o.amount FROM users AS u LEFT JOIN orders AS o ON u.id = o.uid ORDER BY u.id, o.id"
  "SELECT o.uid, count(*) AS c FROM orders o GROUP BY o.uid ORDER BY o.uid"
  "SELECT o.uid, sum(o.amount) AS total FROM orders o GROUP BY o.uid HAVING sum(o.amount) > 100 ORDER BY o.uid"
  # -- GROUP BY + aggregates + HAVING ----------------------------------------
  "SELECT count(*) FROM users"
  "SELECT count(*), count(age), sum(age), min(age), max(age), avg(age) FROM users"
  "SELECT uid, count(*) FROM orders GROUP BY uid ORDER BY uid"
  "SELECT uid, sum(amount), avg(amount), min(amount), max(amount) FROM orders GROUP BY uid ORDER BY uid"
  "SELECT city, count(*) FROM users GROUP BY city ORDER BY city"
  "SELECT uid, count(*) FROM orders GROUP BY uid HAVING count(*) > 1 ORDER BY uid"
  "SELECT uid, sum(amount) FROM orders GROUP BY uid HAVING sum(amount) > 100 ORDER BY uid"
  "SELECT users.name, count(*), sum(orders.amount) FROM users INNER JOIN orders ON users.id = orders.uid GROUP BY users.name ORDER BY users.name"
  "SELECT sum(amount * qty) FROM orders"
  "SELECT uid, sum(amount * qty) FROM orders GROUP BY uid ORDER BY uid"
  "SELECT age, count(*) FROM users GROUP BY age HAVING count(*) > 1"
  # -- ORDER BY: multi-key, ASC/DESC, computed --------------------------------
  "SELECT name, age FROM users ORDER BY age ASC, name DESC"
  "SELECT name, age FROM users ORDER BY age DESC, name ASC"
  "SELECT name, age FROM users ORDER BY age"
  "SELECT amount, qty FROM orders ORDER BY amount * qty DESC, id ASC"
  "SELECT amount, qty FROM orders ORDER BY amount * qty ASC, id ASC"
  "SELECT uid, count(*) FROM orders GROUP BY uid ORDER BY count(*) DESC, uid ASC"
  "SELECT name FROM users ORDER BY age DESC, id ASC"
  # -- LIMIT / OFFSET ---------------------------------------------------------
  "SELECT id, name FROM users ORDER BY id LIMIT 2"
  "SELECT id, name FROM users ORDER BY id LIMIT 2 OFFSET 1"
  "SELECT id, name FROM users ORDER BY id LIMIT 10 OFFSET 3"
  "SELECT id, name FROM users ORDER BY id LIMIT 0"
  "SELECT uid, count(*) FROM orders GROUP BY uid ORDER BY count(*) DESC, uid ASC LIMIT 1"
  "SELECT users.name, count(*) FROM users INNER JOIN orders ON users.id = orders.uid GROUP BY users.name HAVING count(*) > 1 ORDER BY sum(orders.amount) ASC LIMIT 1"
  # -- IS [NOT] NULL ----------------------------------------------------------
  "SELECT name FROM users WHERE age IS NULL"
  "SELECT name FROM users WHERE age IS NOT NULL ORDER BY id"
  "SELECT id FROM orders WHERE amount IS NULL"
  "SELECT id FROM orders WHERE amount IS NOT NULL AND qty > 1 ORDER BY id"
  "SELECT name FROM users WHERE city IS NULL"
  # -- `||` concatenation (NULL propagates; numbers coerce to text) ----------
  "SELECT name || '-' || city FROM users ORDER BY id"
  "SELECT id, amount || '' FROM orders ORDER BY id"
  "SELECT id, 1 || 2 FROM orders WHERE id = 1"
  "SELECT name || NULL FROM users ORDER BY id"
  # -- LIKE / NOT LIKE (case-insensitive ASCII; NULL on either side ⇒ UNKNOWN) -
  "SELECT name FROM users WHERE name LIKE 'a%' ORDER BY id"
  "SELECT name FROM users WHERE name LIKE '_da' ORDER BY id"
  "SELECT name FROM users WHERE name LIKE 'A%' ORDER BY id"
  "SELECT name FROM users WHERE name NOT LIKE 'a%' ORDER BY id"
  "SELECT name FROM users WHERE city LIKE 'p%' ORDER BY id"
  "SELECT name FROM users WHERE city NOT LIKE 'p%' ORDER BY id"
  # -- IN / NOT IN (the classic NULL-in-list trap: UNKNOWN, not FALSE) --------
  "SELECT name FROM users WHERE age IN (24, 30) ORDER BY id"
  "SELECT name FROM users WHERE age NOT IN (24, 30) ORDER BY id"
  "SELECT name FROM users WHERE age IN (24, NULL) ORDER BY id"
  "SELECT name FROM users WHERE age NOT IN (24, NULL) ORDER BY id"
  # -- BETWEEN / NOT BETWEEN (inclusive; NULL on any of the 3 ⇒ UNKNOWN) ------
  "SELECT name FROM users WHERE age BETWEEN 25 AND 30 ORDER BY id"
  "SELECT name FROM users WHERE age NOT BETWEEN 25 AND 30 ORDER BY id"
  "SELECT id FROM orders WHERE amount BETWEEN 100 AND 200 ORDER BY id"
  "SELECT id FROM orders WHERE amount NOT BETWEEN 100 AND 200 ORDER BY id"
  # -- CASE (searched + simple forms; NULL/UNKNOWN WHEN ⇒ not taken) ----------
  "SELECT name, CASE WHEN age > 25 THEN 'old' WHEN age IS NULL THEN 'unknown' ELSE 'young' END FROM users ORDER BY id"
  "SELECT name, CASE WHEN age > 25 THEN 'old' ELSE 'young' END FROM users ORDER BY id"
  "SELECT age, CASE age WHEN 30 THEN 'thirty' WHEN 24 THEN 'twenty-four' ELSE 'other' END FROM users ORDER BY id"
  "SELECT id, CASE WHEN amount IS NULL THEN -1 ELSE amount END FROM orders ORDER BY id"
  # -- COALESCE / IFNULL -------------------------------------------------------
  "SELECT name, COALESCE(city, 'unknown') FROM users ORDER BY id"
  "SELECT name, IFNULL(city, 'unknown') FROM users ORDER BY id"
  "SELECT id, COALESCE(NULL, NULL, 'x') FROM orders WHERE id = 1"
  "SELECT id, COALESCE(amount, 0) FROM orders ORDER BY id"
  # -- TRUE / FALSE literals ---------------------------------------------------
  "SELECT id, TRUE, FALSE FROM orders WHERE id = 1"
  "SELECT name FROM users WHERE age >= 24 AND TRUE ORDER BY id"
  # -- scalar string functions (NULL propagates; non-text coerces to text) ----
  "SELECT upper(name), lower(name) FROM users ORDER BY id"
  "SELECT length(name) FROM users ORDER BY id"
  "SELECT length(city) FROM users ORDER BY id"
  "SELECT id, length(amount) FROM orders ORDER BY id"
  "SELECT substr(name, 1, 2) FROM users ORDER BY id"
  "SELECT substr(name, -2) FROM users ORDER BY id"
  "SELECT substr(name, 2) FROM users ORDER BY id"
  "SELECT substr(city, 1, 2) FROM users ORDER BY id"
  "SELECT trim('  ' || name || '  ') FROM users ORDER BY id"
  "SELECT ltrim('  ' || name) FROM users ORDER BY id"
  "SELECT rtrim(name || '  ') FROM users ORDER BY id"
  "SELECT replace(name, 'a', 'X') FROM users ORDER BY id"
  "SELECT replace(city, 'p', 'X') FROM users ORDER BY id"
  # -- substr's Y=0 / negative-Y / negative-Z corner cases (pin ONE row so the
  #    result doesn't depend on scan order) ------------------------------------
  "SELECT substr('hello', 0, 3) FROM orders WHERE id = 1"
  "SELECT substr('hello', 3, -2) FROM orders WHERE id = 1"
  "SELECT substr('hello', -1, -2) FROM orders WHERE id = 1"
  "SELECT substr('hello', 1, -1) FROM orders WHERE id = 1"
  "SELECT substr('hello', 10) FROM orders WHERE id = 1"
  "SELECT substr('hello', 10, 3) FROM orders WHERE id = 1"
  "SELECT substr('hello', 0) FROM orders WHERE id = 1"
  "SELECT substr('hello', 1, 0) FROM orders WHERE id = 1"
  # -- operator precedence ----------------------------------------------------
  "SELECT name FROM users WHERE age = 30 OR age = 24 AND name = 'cyd' ORDER BY id"
  "SELECT name FROM users WHERE (age = 30 OR age = 24) AND name = 'cyd' ORDER BY id"
  "SELECT id FROM orders WHERE amount + qty * 2 > 105 ORDER BY id"
  "SELECT id FROM orders WHERE (amount + qty) * 2 > 105 ORDER BY id"
  "SELECT name FROM users WHERE NOT age = 30 AND age IS NOT NULL ORDER BY id"
  "SELECT id FROM orders WHERE amount > 50 AND qty < 3 OR uid = 3 ORDER BY id"
  # -- arithmetic coerces a TEXT/BLOB operand to a number (SQLite affinity) ----
  # Longest leading numeric prefix; 0 when there is none; NULL still propagates.
  # A prefix carrying '.' or a valid exponent is REAL, else INTEGER.  (The giant-
  # integer overflow→real case is pulled out of the byte-diff below — it denotes
  # the right double but prints %g-vs-shortest differently, exactly like the avg
  # floats.  See findings/sql-arith-rowid-coercion.md.)
  "SELECT '5' + 2, '5abc' + 2, 'abc' + 2, '' + 2 FROM orders WHERE id = 1"
  "SELECT '3.5' * 2, '3.5' + '2.5' FROM orders WHERE id = 1"
  "SELECT '  5' + 2, '  -3.5 ' + 0, '+7' + 0 FROM orders WHERE id = 1"
  "SELECT '.5' + 0, '5.' + 0, '1e3' + 0, '3.5e2' + 0 FROM orders WHERE id = 1"
  "SELECT '5e' + 0, '5e+' + 0, '0x10' + 2, '007' + 0 FROM orders WHERE id = 1"
  "SELECT '5' / 2, '5.0' / 2, '7' % '3' FROM orders WHERE id = 1"
  "SELECT '1.2.3' + 0, ' 5 6' + 0, '-0' + 0 FROM orders WHERE id = 1"
  "SELECT 'inf' + 0, 'nan' + 0 FROM orders WHERE id = 1"
  "SELECT NULL + '5', '5' + NULL FROM orders WHERE id = 1"
  "SELECT name + 0 FROM users ORDER BY id"
  "SELECT city * 2 FROM users ORDER BY id"
  "SELECT amount * '2' FROM orders ORDER BY id"
  "SELECT id FROM orders WHERE '2abc' + 0 = qty ORDER BY id"
  # -- the implicit rowid column (aliases _rowid_ / oid) ----------------------
  # On a rowid table with an INTEGER PRIMARY KEY, rowid == that column; SELECT *
  # never shows it, WHERE/ORDER BY/projection can all address it.
  "SELECT rowid, name FROM users ORDER BY rowid"
  "SELECT rowid, id, name FROM users ORDER BY id"
  "SELECT _rowid_, name FROM users ORDER BY _rowid_ DESC"
  "SELECT oid, name FROM users ORDER BY oid"
  "SELECT * FROM users WHERE rowid = 2"
  "SELECT name FROM users WHERE rowid > 2 ORDER BY rowid"
  "SELECT name FROM users ORDER BY rowid DESC"
  "SELECT rowid FROM users WHERE oid = _rowid_ ORDER BY rowid"
  "SELECT o.rowid, o.amount FROM orders o WHERE o.rowid <= 3 ORDER BY o.rowid"
  "SELECT users.rowid, orders.rowid FROM users JOIN orders ON users.id = orders.uid ORDER BY orders.rowid"
  # -- case-insensitivity + trailing semicolon --------------------------------
  # Mixed-case KEYWORDS (the parser's job).  Note the IDENTIFIERS stay
  # correctly-cased: sqlite3 folds identifier case, the Medaka engine's
  # findTable/columnIndex do not — a documented engine-side divergence (it is a
  # clean `error: table not found`, never a wrong answer).  See findings F4.
  "select name, age from users where age Is Not Null Order By age Desc, id Asc;"
  "SELECT COUNT(*) FROM orders;"
  "Select Distinct city From users Where city Is Not Null Order By city;"
  # -- SET OPERATIONS: UNION [ALL] / INTERSECT / EXCEPT ------------------------
  # Set-op row order is UNSPECIFIED without an ORDER BY, and the oracle diffs
  # stdout, so EVERY query here carries an explicit ORDER BY (which binds to the
  # WHOLE compound) to make both engines deterministic.  Row identity is
  # full-row equality with NULLs equal — matching SQLite's set-op semantics.
  # UNION dedups; UNION ALL keeps duplicates (uids repeat in orders):
  "SELECT uid FROM orders UNION SELECT uid FROM orders ORDER BY uid"
  "SELECT uid FROM orders UNION ALL SELECT uid FROM orders ORDER BY uid"
  # bob's age is NULL — it survives UNION as a single deduped NULL row:
  "SELECT age FROM users UNION SELECT age FROM users ORDER BY age"
  "SELECT age FROM users UNION ALL SELECT age FROM users ORDER BY age"
  # UNION across two tables:
  "SELECT id FROM users UNION SELECT uid FROM orders ORDER BY id"
  "SELECT id FROM users UNION ALL SELECT uid FROM orders ORDER BY id"
  # INTERSECT — rows in BOTH, deduped (users 1..4 vs order uids 1,2,3):
  "SELECT id FROM users INTERSECT SELECT uid FROM orders ORDER BY id"
  "SELECT uid FROM orders INTERSECT SELECT id FROM users ORDER BY uid"
  # NULL is present in both sides ⇒ NULL is in the INTERSECT (NULLs equal):
  "SELECT age FROM users INTERSECT SELECT age FROM users ORDER BY age"
  # EXCEPT — left rows absent from the right, deduped:
  "SELECT id FROM users EXCEPT SELECT uid FROM orders ORDER BY id"
  "SELECT uid FROM orders EXCEPT SELECT id FROM users ORDER BY uid"
  "SELECT age FROM users EXCEPT SELECT age FROM users WHERE age > 25 ORDER BY age"
  "SELECT city FROM users UNION SELECT city FROM users ORDER BY city"
  # multi-arm chains — LEFT-associative, all set operators the same precedence:
  "SELECT id FROM users UNION SELECT uid FROM orders INTERSECT SELECT id FROM users ORDER BY id"
  "SELECT id FROM users UNION SELECT uid FROM orders EXCEPT SELECT id FROM users WHERE id = 2 ORDER BY id"
  "SELECT uid FROM orders UNION ALL SELECT id FROM users UNION SELECT qty FROM orders ORDER BY uid"
  # trailing LIMIT / OFFSET / ordinal ORDER BY on the WHOLE compound:
  "SELECT id FROM users UNION SELECT uid FROM orders ORDER BY id LIMIT 2"
  "SELECT id FROM users UNION SELECT uid FROM orders ORDER BY id DESC LIMIT 2 OFFSET 1"
  "SELECT id FROM users UNION SELECT uid FROM orders ORDER BY 1 DESC"
  # multi-column arms; per-arm WHERE / JOIN stays on its arm:
  "SELECT name, age FROM users WHERE age IS NOT NULL UNION SELECT city, id FROM users ORDER BY name, age"
  "SELECT id, city FROM users UNION SELECT uid, name FROM orders JOIN users ON orders.uid = users.id ORDER BY id, city"
  # arm-level DISTINCT (honoured, deduped in cell-land) + a GROUP BY/HAVING arm:
  "SELECT DISTINCT age FROM users UNION SELECT age FROM users ORDER BY age"
  "SELECT uid FROM orders GROUP BY uid HAVING count(*) > 1 UNION SELECT id FROM users WHERE id > 3 ORDER BY uid"
  # case-insensitive set-op keywords:
  "select id from users Union All select uid from orders Order By id"
)

# ── 2. REJECTION CORPUS ───────────────────────────────────────────────────────
# SQL we cannot represent.  Each MUST print an `error: ...` line — a clean Err,
# never a silently-dropped clause and never a panic.  sqlite3 executes most of
# these fine; we refuse ON PURPOSE, which is the whole point of the section.
REJECTS=(
  # set-op arm column-count mismatch — SQLite rejects at prepare time (even on
  # empty tables); so do we, with the same message shape, for every operator.
  "SELECT id, name FROM users UNION SELECT uid FROM orders"
  "SELECT id FROM users UNION ALL SELECT uid, amount FROM orders"
  "SELECT id FROM users INTERSECT SELECT uid, amount FROM orders"
  "SELECT id, name FROM users EXCEPT SELECT uid FROM orders"
  "SELECT id FROM users UNION SELECT uid FROM orders INTERSECT SELECT id, name FROM users"
  # a set-op arm with no FROM (SELECT of a bare constant) — unsupported by the
  # whole engine (selectCore requires FROM), a clean Err not a wrong answer.
  "SELECT id FROM users UNION SELECT 1"
  # sub-queries / CTEs (still unsupported)
  "SELECT id FROM users WHERE id IN (SELECT uid FROM orders)"
  # unsupported expression syntax: the ESCAPE clause, GLOB/MATCH/REGEXP,
  # COLLATE, JSON arrows, an unknown scalar function, malformed CASE/IN
  "SELECT name FROM users WHERE name LIKE 'a%' ESCAPE '\\'"
  "SELECT name FROM users WHERE name GLOB 'a*'"
  "SELECT name FROM users WHERE name MATCH 'a'"
  "SELECT name FROM users WHERE name REGEXP 'a'"
  "SELECT name FROM users WHERE age > 25 COLLATE NOCASE"
  "SELECT foo(name) FROM users"
  "SELECT CASE END FROM users"
  "SELECT name FROM users WHERE age IN ()"
  # unsupported joins
  "SELECT users.name FROM users CROSS JOIN orders"
  "SELECT users.name FROM users NATURAL JOIN orders"
  "SELECT users.name FROM users RIGHT JOIN orders ON users.id = orders.uid"
  "SELECT users.name FROM users JOIN orders USING (uid)"
  # aggregate in a per-row position (SQL forbids it; so do we, at PARSE time)
  "SELECT name FROM users WHERE count(*) > 1"
  "SELECT users.name FROM users JOIN orders ON count(*) > 1"
  "SELECT sum(count(age)) FROM users"
  # the GROUP BY rule: a non-aggregate projection that is not a key
  "SELECT name, count(*) FROM users GROUP BY city"
  # ill-formed / half-written statements must blame the right spot, not shrug
  "SELECT * FROM"
  "SELECT FROM users"
  "SELECT a, FROM users"
  "SELECT * FROM users WHERE"
  "SELECT * FROM users WHERE age >"
  "SELECT * FROM users ORDER BY"
  "SELECT * FROM users LIMIT"
  "SELECT * FROM users LIMIT 'x'"
  "SELECT * FROM users GROUP BY"
  "SELECT * FROM main.users"
  "SELECT *, name FROM users"
  "SELECT sum(*) FROM orders"
  # a real engine error (not a parse error): unknown column, cleanly reported
  "SELECT nosuch FROM users"
  "SELECT * FROM nosuchtable"
)

# ── run section 1 ─────────────────────────────────────────────────────────────
qpass=0; qfail=0
for q in "${QUERIES[@]}"; do
  want="$(sqlite3 "$DB" "$q" 2>&1)"
  got="$("$BIN" "$DB" "$q" 2>&1)"
  if [ "$got" = "$want" ]; then
    qpass=$((qpass + 1))
  else
    qfail=$((qfail + 1))
    echo "DIFF: $q"
    diff <(printf '%s\n' "$got") <(printf '%s\n' "$want") | sed 's/^/    /'
  fi
done

# ── run section 2 ─────────────────────────────────────────────────────────────
rpass=0; rfail=0
for q in "${REJECTS[@]}"; do
  got="$("$BIN" "$DB" "$q" 2>&1)"
  st=$?
  case "$got" in
    error:*)
      if [ "$st" -eq 0 ]; then rpass=$((rpass + 1))
      else rfail=$((rfail + 1)); echo "REJECT-EXIT $st: $q"; fi
      ;;
    *)
      rfail=$((rfail + 1))
      echo "NOT-REJECTED: $q"
      echo "    got: $got"
      ;;
  esac
done

# ── FLOAT ROUND-TRIP: inexact floats PRINT differently but denote the SAME double ─
# Medaka's `floatToString` emits SHORTEST-ROUND-TRIP digits (issue #57): the fewest
# digits that read back to the identical IEEE double.  sqlite3 renders C `%.15g`
# (15 significant digits), which is SHORTER and — unlike Medaka's form — does NOT
# itself round-trip (15 digits cannot always identify a double; 17 can).  So the two
# printed strings for an inexact avg like 85/3 differ (Medaka `28.333333333333332`,
# sqlite3 `28.3333333333333`) yet are the SAME double.
#
# Assert exactly that INVARIANT: CAST Medaka's text back to REAL via sqlite3's own
# strtod and compare to the value the query computes.  Comparing the two PRINTED
# strings (the pre-#57 "Medaka is a PREFIX of sqlite3" check) is now wrong twice
# over — Medaka is the longer/precise side, and sqlite3's own string does not
# round-trip, so `CAST(sqlite3_text)` would not even reproduce sqlite3's own double.
# See findings/sql-parser-select.md F3.
FLOAT_QUERIES=(
  "SELECT avg(amount) FROM orders WHERE amount IS NOT NULL AND uid = 1 OR uid = 3"
  "SELECT sum(amount) / 7.0 FROM orders"
  "SELECT amount / 3.0 FROM orders WHERE id = 1"
)
fpass=0; ffail=0
for q in "${FLOAT_QUERIES[@]}"; do
  got="$("$BIN" "$DB" "$q" 2>&1)"
  # Each query is a single-row, single-column SELECT, so `($q)` is a scalar
  # subquery: sqlite3 evaluates the true double, CASTs Medaka's shortest-round-trip
  # text back to REAL, and compares.  "1" ⇔ Medaka's printed value round-trips to
  # exactly the double sqlite3 computed.
  same="$(sqlite3 "$DB" "SELECT CAST('$got' AS REAL) = ($q);" 2>&1)"
  if [ "$same" = "1" ]; then fpass=$((fpass + 1))
  else
    ffail=$((ffail + 1))
    want="$(sqlite3 "$DB" "$q" 2>&1)"
    echo "FLOAT-DIVERGE (wrong VALUE, not formatting): $q"
    echo "    medaka : $got"
    echo "    sqlite3: $want   (CAST-equal to query double? $same)"
  fi
done

# ── run section 3: round trip (parseSelect → renderSelect → parseSelect) ──────
# The probe carries the same query corpus and asserts `Select` equality, plus a
# parse-level rejection corpus and exact-shape assertions.  Its verdict is the
# LAST LINE of stdout, not an exit code (`exit` is unimplemented in the
# interpreter — see sqlite/findings/sql-parser-select.md F2 — so the probe stays
# runnable under BOTH `medaka run` and a native build).
probe_out="$("$PROBE")"
probe_st=1
case "$probe_out" in *"TOTAL: PASS") probe_st=0 ;; esac

echo
echo "queries:    $qpass ok, $qfail diffs   (vs sqlite3, ${#QUERIES[@]} SQL strings)"
echo "rejections: $rpass ok, $rfail bad     (${#REJECTS[@]} unsupported SQL strings)"
echo "float-prec: $fpass ok, $ffail bad     (${#FLOAT_QUERIES[@]} inexact floats: same double, different %g width)"
echo "$probe_out"

if [ "$qfail" -eq 0 ] && [ "$rfail" -eq 0 ] && [ "$ffail" -eq 0 ] && [ "$probe_st" -eq 0 ]; then
  echo "PASS: SQL-string query output matches sqlite3; every unsupported construct is a clean Err"
  exit 0
else
  echo "FAIL: SQL-string oracle diverged"
  exit 1
fi
