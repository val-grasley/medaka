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
# 165.0).  Not cosmetic: Medaka's `floatToString` renders only ~12 significant
# digits, so an inexact avg like 85/3 prints `28.3333333333` where sqlite3 prints
# `28.3333333333333` and the diff is a FORMATTING artefact, not a query bug.  That
# divergence is real and is asserted deliberately in the FLOAT_PREFIX section
# below rather than swept under the rug.  See findings/sql-parser-select.md F3.
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
  # -- operator precedence ----------------------------------------------------
  "SELECT name FROM users WHERE age = 30 OR age = 24 AND name = 'cyd' ORDER BY id"
  "SELECT name FROM users WHERE (age = 30 OR age = 24) AND name = 'cyd' ORDER BY id"
  "SELECT id FROM orders WHERE amount + qty * 2 > 105 ORDER BY id"
  "SELECT id FROM orders WHERE (amount + qty) * 2 > 105 ORDER BY id"
  "SELECT name FROM users WHERE NOT age = 30 AND age IS NOT NULL ORDER BY id"
  "SELECT id FROM orders WHERE amount > 50 AND qty < 3 OR uid = 3 ORDER BY id"
  # -- case-insensitivity + trailing semicolon --------------------------------
  # Mixed-case KEYWORDS (the parser's job).  Note the IDENTIFIERS stay
  # correctly-cased: sqlite3 folds identifier case, the Medaka engine's
  # findTable/columnIndex do not — a documented engine-side divergence (it is a
  # clean `error: table not found`, never a wrong answer).  See findings F4.
  "select name, age from users where age Is Not Null Order By age Desc, id Asc;"
  "SELECT COUNT(*) FROM orders;"
  "Select Distinct city From users Where city Is Not Null Order By city;"
)

# ── 2. REJECTION CORPUS ───────────────────────────────────────────────────────
# SQL we cannot represent.  Each MUST print an `error: ...` line — a clean Err,
# never a silently-dropped clause and never a panic.  sqlite3 executes most of
# these fine; we refuse ON PURPOSE, which is the whole point of the section.
REJECTS=(
  # set operations / sub-queries / CTEs
  "SELECT a FROM t UNION SELECT b FROM u"
  "SELECT a FROM t INTERSECT SELECT b FROM u"
  "SELECT id FROM users WHERE id IN (SELECT uid FROM orders)"
  # aliases
  "SELECT name AS n FROM users"
  "SELECT u.name FROM users u"
  # unsupported expression syntax
  "SELECT name FROM users WHERE name LIKE 'a%'"
  "SELECT name FROM users WHERE age BETWEEN 20 AND 30"
  "SELECT name FROM users WHERE age IN (25, 30)"
  "SELECT CASE WHEN age > 25 THEN 1 ELSE 0 END FROM users"
  "SELECT name || city FROM users"
  "SELECT upper(name) FROM users"
  "SELECT name FROM users WHERE age > 25 COLLATE NOCASE"
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
  "SELECT * FROM users EXTRA"
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

# ── FLOAT_PREFIX: the ONE known, documented divergence ────────────────────────
# Medaka's `floatToString` emits ~12 significant digits; sqlite3 (C `%!.15g`)
# emits 15.  So an inexact float renders SHORTER, not WRONGLY.  Rather than
# excluding such queries and pretending the problem doesn't exist, assert exactly
# what is true: Medaka's answer is a PREFIX of sqlite3's.  The day `floatToString`
# is fixed this section starts passing as an exact match too (a prefix of itself),
# so it never has to be revisited.  See findings/sql-parser-select.md F3.
FLOAT_QUERIES=(
  "SELECT avg(amount) FROM orders WHERE amount IS NOT NULL AND uid = 1 OR uid = 3"
  "SELECT sum(amount) / 7.0 FROM orders"
  "SELECT amount / 3.0 FROM orders WHERE id = 1"
)
fpass=0; ffail=0
for q in "${FLOAT_QUERIES[@]}"; do
  want="$(sqlite3 "$DB" "$q" 2>&1)"
  got="$("$BIN" "$DB" "$q" 2>&1)"
  case "$want" in
    "$got"*) fpass=$((fpass + 1)) ;;
    *)
      ffail=$((ffail + 1))
      echo "FLOAT-DIVERGE (not a mere truncation): $q"
      echo "    medaka : $got"
      echo "    sqlite3: $want"
      ;;
  esac
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
echo "float-prec: $fpass ok, $ffail bad     (${#FLOAT_QUERIES[@]} known floatToString truncations)"
echo "$probe_out"

if [ "$qfail" -eq 0 ] && [ "$rfail" -eq 0 ] && [ "$ffail" -eq 0 ] && [ "$probe_st" -eq 0 ]; then
  echo "PASS: SQL-string query output matches sqlite3; every unsupported construct is a clean Err"
  exit 0
else
  echo "FAIL: SQL-string oracle diverged"
  exit 1
fi
