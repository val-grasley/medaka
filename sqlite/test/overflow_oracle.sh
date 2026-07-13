#!/usr/bin/env bash
# Differential oracle for OVERFLOW PAGES (read + write), vs the real sqlite3 CLI.
#
# A payload too large for its b-tree leaf cell is split: `localPayloadSize` bytes
# stay in the cell, the rest go onto a chain of overflow pages (see
# sqlite/lib/overflow.mdk).  Getting the threshold arithmetic even one byte wrong
# silently corrupts data, so this gate is a DENSE BOUNDARY SWEEP, not a spot check.
#
# What it proves:
#   1. BOUNDARY SWEEP — Medaka writes rows at every size from 4030..4075 (the
#      local-payload limit X = 4061 falls inside that window), plus 1 / 100 /
#      5 KB / 8.2 KB / 12.3 KB / 100 KB.  Every value must come back
#      BYTE-IDENTICAL from sqlite3, and `PRAGMA integrity_check` must say `ok`.
#      Both TEXT and BLOB.  The expected bytes are generated INDEPENDENTLY in
#      Python, so a shared bug in the Medaka reader+writer cannot hide.
#   2. The sweep actually straddles the threshold — asserted via sqlite3's own
#      `dbstat` (some rows local, some with overflow pages).
#   3. ROUND-TRIP — Medaka reads its own file back identically to sqlite3.
#   4. MULTI-BIG-COLUMN rows (both TEXT and BLOB large in the same record).
#   5. THE MUTATE WALL IS GONE — UPDATE and DELETE on a table containing an
#      overflow row succeed, keep the db valid, and produce exactly the table
#      state sqlite3 produces for the same statement.
#   6. A db written by REAL sqlite3 with big rows, then mutated by Medaka, is
#      still valid and correct in sqlite3.
#
# Usage: sqlite/test/overflow_oracle.sh
# Requires: sqlite3 + python3 on PATH; the Medaka tree built.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

MEDAKA="$ROOT/medaka"
DEMO="$ROOT/sqlite_overflow_demo"
export MEDAKA_EMITTER="$ROOT/medaka_emitter"
export MEDAKA_ROOT="$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
note() { echo "  $*"; }
check() {
  # check <label> <expected-file> <actual-file>
  if diff -q "$2" "$3" >/dev/null 2>&1; then
    echo "OK: $1"
  else
    echo "FAIL: $1"
    diff -u "$2" "$3" | head -20
    fail=1
  fi
}
expect_eq() {
  # expect_eq <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "OK: $1"
  else
    echo "FAIL: $1 (expected '$2', got '$3')"
    fail=1
  fi
}

# The table every mode of overflow_demo uses.
SCHEMA="CREATE TABLE big(id INTEGER PRIMARY KEY, t TEXT, b BLOB, n INTEGER)"
SELECT="SELECT id, t, hex(b), n FROM big"

# Regenerate the deterministic payloads INDEPENDENTLY (mirrors textOf/blobOf in
# sqlite/overflow_demo.mdk).  This is the third opinion: if Medaka's writer and
# reader shared a bug, sqlite3 + this Python would both disagree with them.
gen_expected() {
  # gen_expected <mode:write|writemix> <size>...
  python3 - "$@" <<'PY'
import sys
mode, sizes = sys.argv[1], [int(x) for x in sys.argv[2:]]
def text(n): return "".join(chr(97 + (i % 26)) for i in range(n))
def blob(n): return bytes((i * 7 + 3) % 256 for i in range(n))
rid = 1
for s in sizes:
    if mode == "write":
        print(f"{rid}|{text(s)}||{s}"); rid += 1
        print(f"{rid}||{blob(s).hex().upper()}|{s}"); rid += 1
    else:
        print(f"{rid}|{text(s)}|{blob(s).hex().upper()}|{s}"); rid += 1
PY
}

echo "=== building sqlite/overflow_demo.mdk"
"$MEDAKA" build sqlite/overflow_demo.mdk >/dev/null
mv -f "$ROOT/overflow_demo" "$DEMO"

# ---------------------------------------------------------------------------
# 1. Boundary sweep: Medaka WRITES; sqlite3 must read every byte back.
# ---------------------------------------------------------------------------
# 4030..4075 brackets the local-payload limit X = 4061.  For these single-big-
# column rows the record payload is size+8, so the spill starts at size 4054
# (payload 4062) and size 4053 (payload 4061 == X exactly) is the last local
# one — the classic off-by-one lands squarely inside this window.
SWEEP="$(seq 4030 4075 | tr '\n' ' ') 1 100 5000 8200 12300 100000"

echo
echo "=== 1. boundary sweep (TEXT + BLOB), sizes: 4030..4075 1 100 5000 8200 12300 100000"
DB="$TMP/sweep.db"
# shellcheck disable=SC2086
"$DEMO" write "$DB" $SWEEP >/dev/null

expect_eq "sweep: PRAGMA integrity_check" "ok" "$(sqlite3 "$DB" 'PRAGMA integrity_check;')"

# shellcheck disable=SC2086
gen_expected write $SWEEP > "$TMP/sweep.expected"
sqlite3 -separator '|' "$DB" "$SELECT;" > "$TMP/sweep.sqlite3"
check "sweep: sqlite3 reads Medaka's file byte-identically (104 rows, TEXT + BLOB)" \
      "$TMP/sweep.expected" "$TMP/sweep.sqlite3"

# 3. Round-trip: the Medaka READER must agree with sqlite3 on the same file.
"$DEMO" read "$DB" > "$TMP/sweep.medaka"
check "sweep: Medaka reads its own file identically to sqlite3 (round-trip)" \
      "$TMP/sweep.sqlite3" "$TMP/sweep.medaka"

# 2. The sweep must actually straddle the threshold, or it proves nothing.
NOVF="$(sqlite3 "$DB" "SELECT count(*) FROM dbstat('main') WHERE pagetype='overflow';")"
NLEAF="$(sqlite3 "$DB" "SELECT count(*) FROM dbstat('main') WHERE pagetype='leaf';")"
if [ "$NOVF" -gt 0 ] && [ "$NLEAF" -gt 0 ]; then
  echo "OK: sweep straddles the threshold ($NOVF overflow pages, $NLEAF leaf pages per sqlite3 dbstat)"
else
  echo "FAIL: sweep did not exercise overflow ($NOVF overflow pages, $NLEAF leaf pages)"
  fail=1
fi

# The exact spill boundary, per sqlite3's own page classification.
for s in 4053 4054; do
  B="$TMP/b$s.db"
  "$DEMO" write "$B" "$s" >/dev/null
  GOT="$(sqlite3 "$B" "SELECT count(*) FROM dbstat('main') WHERE pagetype='overflow';")"
  if [ "$s" = 4053 ]; then
    expect_eq "size 4053 (payload 4061 == X) stays local: 0 overflow pages" "0" "$GOT"
  else
    expect_eq "size 4054 (payload 4062 > X) spills: 2 overflow pages" "2" "$GOT"
  fi
done

# ---------------------------------------------------------------------------
# 4. Multi-big-column rows: TEXT and BLOB both large in one record.
# ---------------------------------------------------------------------------
echo
echo "=== 4. rows with TWO big columns (payload ~2x size)"
MIX="5000 20000 60000"
DBM="$TMP/mix.db"
# shellcheck disable=SC2086
"$DEMO" writemix "$DBM" $MIX >/dev/null
expect_eq "writemix: PRAGMA integrity_check" "ok" "$(sqlite3 "$DBM" 'PRAGMA integrity_check;')"
# shellcheck disable=SC2086
gen_expected writemix $MIX > "$TMP/mix.expected"
sqlite3 -separator '|' "$DBM" "$SELECT;" > "$TMP/mix.sqlite3"
check "writemix: sqlite3 reads Medaka's file byte-identically" \
      "$TMP/mix.expected" "$TMP/mix.sqlite3"
"$DEMO" read "$DBM" > "$TMP/mix.medaka"
check "writemix: Medaka round-trips its own file" "$TMP/mix.sqlite3" "$TMP/mix.medaka"

# ---------------------------------------------------------------------------
# 5. The mutate wall: UPDATE / DELETE on a table holding an overflow row.
# ---------------------------------------------------------------------------
# Before overflow-write existed, a table containing ONE >4KB row made EVERY
# UPDATE and DELETE on it fail ("row too large for one page"), because both work
# by rewriting the whole file.  These cases are the proof that wall is gone.
echo
echo "=== 5. UPDATE / DELETE on a table containing a 100 KB row"
MUT="5 4062 100000"

# --- 5a. UPDATE row 1 (a small row) to 9000 bytes: crosses INTO overflow, in a
#         table that already contains a 100 KB overflow row.
DBU="$TMP/upd.db"
# shellcheck disable=SC2086
"$DEMO" write "$DBU" $MUT >/dev/null
OUT="$("$DEMO" update "$DBU" 1 9000)"
expect_eq "UPDATE reports 1 row updated" "updated 1" "$OUT"
expect_eq "UPDATE: PRAGMA integrity_check" "ok" "$(sqlite3 "$DBU" 'PRAGMA integrity_check;')"

# The same statement, executed by real sqlite3 on a pristine copy of the input.
DBU_REF="$TMP/upd_ref.db"
# shellcheck disable=SC2086
"$DEMO" write "$DBU_REF" $MUT >/dev/null
python3 - "$DBU_REF" <<'PY'
import sqlite3, sys
def text(n): return "".join(chr(97 + (i % 26)) for i in range(n))
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE big SET t = ?, n = ? WHERE id = 1", (text(9000), 9000))
c.commit(); c.close()
PY
sqlite3 -separator '|' "$DBU"     "$SELECT;" > "$TMP/upd.medaka"
sqlite3 -separator '|' "$DBU_REF" "$SELECT;" > "$TMP/upd.sqlite3"
check "UPDATE: Medaka's result == sqlite3's result for the same statement" \
      "$TMP/upd.sqlite3" "$TMP/upd.medaka"
"$DEMO" read "$DBU" > "$TMP/upd.readback"
check "UPDATE: Medaka reads the mutated file back identically" \
      "$TMP/upd.medaka" "$TMP/upd.readback"

# --- 5b. DELETE a row from a table containing a 100 KB overflow row.
DBD="$TMP/del.db"
# shellcheck disable=SC2086
"$DEMO" write "$DBD" $MUT >/dev/null
OUT="$("$DEMO" delete "$DBD" 2)"
expect_eq "DELETE reports 1 row deleted" "deleted 1" "$OUT"
expect_eq "DELETE: PRAGMA integrity_check" "ok" "$(sqlite3 "$DBD" 'PRAGMA integrity_check;')"

DBD_REF="$TMP/del_ref.db"
# shellcheck disable=SC2086
"$DEMO" write "$DBD_REF" $MUT >/dev/null
sqlite3 "$DBD_REF" "DELETE FROM big WHERE id = 2;"
sqlite3 -separator '|' "$DBD"     "$SELECT;" > "$TMP/del.medaka"
sqlite3 -separator '|' "$DBD_REF" "$SELECT;" > "$TMP/del.sqlite3"
check "DELETE: Medaka's result == sqlite3's result for the same statement" \
      "$TMP/del.sqlite3" "$TMP/del.medaka"

# --- 5c. DELETE the BIG rows themselves, and prove their chains are RECLAIMED.
# `integrity_check` reports "Page N is never used" for an orphan, so a chain
# left dangling by the rewrite would be caught here rather than silently
# bloating the file.
ovcount() { sqlite3 "$1" "SELECT count(*) FROM dbstat('main') WHERE pagetype='overflow';"; }

DBD2="$TMP/del2.db"
# shellcheck disable=SC2086
"$DEMO" write "$DBD2" $MUT >/dev/null
OV_BEFORE="$(ovcount "$DBD2")"
"$DEMO" delete "$DBD2" 6 >/dev/null   # the 100 KB BLOB row
OV_AFTER="$(ovcount "$DBD2")"
expect_eq "DELETE of the 100 KB row: integrity_check (no orphan pages)" "ok" \
          "$(sqlite3 "$DBD2" 'PRAGMA integrity_check;')"
expect_eq "DELETE of the 100 KB row: it is gone" "0" \
          "$(sqlite3 "$DBD2" 'SELECT count(*) FROM big WHERE id = 6;')"
# The 100 KB blob's chain was 24 pages; the other big rows keep theirs.
expect_eq "DELETE of the 100 KB row: its 24-page chain is reclaimed" \
          "$((OV_BEFORE - 24))" "$OV_AFTER"

# Delete every remaining big row: NO overflow page may survive.
for r in 3 4 5; do "$DEMO" delete "$DBD2" "$r" >/dev/null; done
expect_eq "DELETE of all big rows: integrity_check" "ok" \
          "$(sqlite3 "$DBD2" 'PRAGMA integrity_check;')"
expect_eq "DELETE of all big rows: every overflow chain reclaimed" "0" "$(ovcount "$DBD2")"
expect_eq "DELETE of all big rows: the 2 small rows survive" "2" \
          "$(sqlite3 "$DBD2" 'SELECT count(*) FROM big;')"

# ---------------------------------------------------------------------------
# 6. A REAL sqlite3 database with big rows, mutated by Medaka.
# ---------------------------------------------------------------------------
echo
echo "=== 6. sqlite3-created db with big rows, mutated by Medaka"
DBR="$TMP/real.db"
DBR_REF="$TMP/real_ref.db"
for target in "$DBR" "$DBR_REF"; do
  python3 - "$target" "$SCHEMA" <<'PY'
import sqlite3, sys
def text(n): return "".join(chr(97 + (i % 26)) for i in range(n))
def blob(n): return bytes((i * 7 + 3) % 256 for i in range(n))
c = sqlite3.connect(sys.argv[1])
c.execute(sys.argv[2])
for rid, s in enumerate([7, 10000, 3000, 50000], start=1):
    c.execute("INSERT INTO big VALUES (?, ?, ?, ?)", (rid, text(s), blob(s), s))
c.commit(); c.close()
PY
done

# Medaka must read the real file correctly to begin with.
sqlite3 -separator '|' "$DBR" "$SELECT;" > "$TMP/real.sqlite3"
"$DEMO" read "$DBR" > "$TMP/real.medaka"
check "real db: Medaka reads sqlite3's overflow rows byte-identically" \
      "$TMP/real.sqlite3" "$TMP/real.medaka"

# Now mutate it with Medaka; sqlite3 must still accept and agree.
"$DEMO" update "$DBR" 3 30000 >/dev/null
"$DEMO" delete "$DBR" 1 >/dev/null
python3 - "$DBR_REF" <<'PY'
import sqlite3, sys
def text(n): return "".join(chr(97 + (i % 26)) for i in range(n))
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE big SET t = ?, n = ? WHERE id = 3", (text(30000), 30000))
c.execute("DELETE FROM big WHERE id = 1")
c.commit(); c.close()
PY
expect_eq "real db mutated by Medaka: integrity_check" "ok" \
          "$(sqlite3 "$DBR" 'PRAGMA integrity_check;')"
sqlite3 -separator '|' "$DBR"     "$SELECT;" > "$TMP/real_mut.medaka"
sqlite3 -separator '|' "$DBR_REF" "$SELECT;" > "$TMP/real_mut.sqlite3"
check "real db: Medaka's UPDATE+DELETE == sqlite3's UPDATE+DELETE" \
      "$TMP/real_mut.sqlite3" "$TMP/real_mut.medaka"

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS: overflow pages (read + write) agree with sqlite3"
else
  echo "FAIL: overflow oracle"
fi
exit "$fail"
