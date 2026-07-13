#!/usr/bin/env bash
# UPDATE ... SET <expr> oracle for sqlite/lib/mutate.mdk + lib/select.mdk.
#
# Proves the Medaka arithmetic UPDATE path matches the sqlite3 CLI byte-for-byte
# on every arithmetic shape:
#   * column-relative:    SET total = total + 10 WHERE total >= 50
#   * scalar multiply:    SET x = x * 2
#   * cross-column:       SET c = a + b
#   * integer division:   SET n = n / 2   (truncates toward zero, incl. negatives)
#   * division by zero:   SET n = n / d   (d = 0  ->  NULL)
#   * modulo:             SET n = n % 3   (sign follows dividend, incl. negatives)
#   * multi-assign swap:  SET a = b, b = a  (RHS evaluated against ORIGINAL row)
#   * float arithmetic:   SET p = p * 1.5  (Float-in-Cell path)
#
# Method: seed ONE database with sqlite3; copy it; run the Medaka probe on copy A
# and the equivalent UPDATE statements via the sqlite3 CLI on copy B; then diff
# the resulting table state (SELECT * ORDER BY id) for every table.  sqlite3 is
# the arbiter — no committed golden.
#
# Requires: sqlite3 on PATH; the Medaka tree built (`make medaka`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

command -v sqlite3 >/dev/null || { echo "FAIL: sqlite3 not on PATH"; exit 1; }

TMP="$(mktemp -d)"
DBM="$TMP/medaka.db"   # mutated by the Medaka probe
DBS="$TMP/sqlite.db"   # mutated by the sqlite3 CLI (the oracle)
trap 'rm -rf "$TMP"' EXIT

MEDAKA="$ROOT/medaka"
PROBE="$ROOT/update_expr_demo"
export MEDAKA_ROOT="$ROOT"
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

# 1. Build the Medaka arithmetic-UPDATE probe binary.
"$MEDAKA" build --allow-internal sqlite/update_expr_demo.mdk -o "$PROBE" >/dev/null

# 2. Seed the database (one file, eight tables).  ids start at 1 so `id >= 0`
#    used inside the probe is a full-table WHERE.
SEED="
CREATE TABLE t1(id INTEGER PRIMARY KEY, total INTEGER);
INSERT INTO t1 VALUES(1,100),(2,50),(3,5);
CREATE TABLE t2(id INTEGER PRIMARY KEY, x INTEGER);
INSERT INTO t2 VALUES(1,3),(2,7);
CREATE TABLE t3(id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, c INTEGER);
INSERT INTO t3 VALUES(1,2,3,0),(2,10,20,0);
CREATE TABLE t4(id INTEGER PRIMARY KEY, n INTEGER);
INSERT INTO t4 VALUES(1,7),(2,-7);
CREATE TABLE t5(id INTEGER PRIMARY KEY, n INTEGER, d INTEGER);
INSERT INTO t5 VALUES(1,10,0);
CREATE TABLE t6(id INTEGER PRIMARY KEY, n INTEGER);
INSERT INTO t6 VALUES(1,7),(2,-7);
CREATE TABLE t7(id INTEGER PRIMARY KEY, a INTEGER, b INTEGER);
INSERT INTO t7 VALUES(1,100,200);
CREATE TABLE t8(id INTEGER PRIMARY KEY, p REAL);
INSERT INTO t8 VALUES(1,2.5),(2,4.0);
"
rm -f "$DBM"
sqlite3 "$DBM" "$SEED"
cp "$DBM" "$DBS"

# 3. Run the Medaka probe on DBM.
echo "=== Medaka probe output ==="
PROBE_OUT="$("$PROBE" "$DBM")"
echo "$PROBE_OUT"

# 4. Apply the EQUIVALENT statements via the sqlite3 CLI on DBS.
sqlite3 "$DBS" "
UPDATE t1 SET total = total + 10 WHERE total >= 50;
UPDATE t2 SET x = x * 2 WHERE id >= 0;
UPDATE t3 SET c = a + b WHERE id >= 0;
UPDATE t4 SET n = n / 2 WHERE id >= 0;
UPDATE t5 SET n = n / d WHERE id >= 0;
UPDATE t6 SET n = n % 3 WHERE id >= 0;
UPDATE t7 SET a = b, b = a WHERE id >= 0;
UPDATE t8 SET p = p * 1.5 WHERE id >= 0;
"

fail=0

# Gate 1: integrity_check on the Medaka-mutated db.
echo "=== Gate 1: PRAGMA integrity_check (Medaka db) ==="
IC="$(sqlite3 "$DBM" "PRAGMA integrity_check;")"
if [ "$IC" = "ok" ]; then echo "OK: integrity_check = ok"; else echo "FAIL: integrity_check = $IC"; fail=1; fi

# Gate 2: expected updated-row counts in the probe output.
echo "=== Gate 2: updated-row counts ==="
check_count() {
  if echo "$PROBE_OUT" | grep -qF "$1"; then echo "OK: $1"; else echo "FAIL: missing '$1'"; fail=1; fi
}
check_count "t1 total+=10 WHERE total>=50: updated 2 rows"
check_count "t2 x*=2: updated 2 rows"
check_count "t3 c=a+b: updated 2 rows"
check_count "t4 n=n/2: updated 2 rows"
check_count "t5 n=n/d (div by zero): updated 1 rows"
check_count "t6 n=n%3: updated 2 rows"
check_count "t7 swap a,b: updated 1 rows"
check_count "t8 p*=1.5 (float): updated 2 rows"

# Gate 3: per-table state Medaka == sqlite3 (the arithmetic-semantics arbiter).
echo "=== Gate 3: table state Medaka vs sqlite3 ==="
for t in t1 t2 t3 t4 t5 t6 t7 t8; do
  # .nullvalue NULL renders NULL literally so the div-by-zero case is visible.
  MM="$(sqlite3 "$DBM" ".mode list" ".nullvalue NULL" "SELECT * FROM $t ORDER BY id;")"
  SS="$(sqlite3 "$DBS" ".mode list" ".nullvalue NULL" "SELECT * FROM $t ORDER BY id;")"
  if [ "$MM" = "$SS" ]; then
    echo "OK $t: $(echo "$MM" | tr '\n' ' ')"
  else
    echo "FAIL $t"
    echo "  medaka: $(echo "$MM" | tr '\n' ' ')"
    echo "  sqlite: $(echo "$SS" | tr '\n' ' ')"
    fail=1
  fi
done

if [ "$fail" = 0 ]; then echo "=== ALL GATES PASS ==="; else echo "=== FAILURES ABOVE ==="; fi
exit "$fail"
