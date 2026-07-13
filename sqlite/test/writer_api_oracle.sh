#!/usr/bin/env bash
# Differential oracle for the Medaka SQLite WRITE-path P4 API (writer.mdk).
#
# Builds fresh single-table .db files FROM SCRATCH with the Medaka P4 API
# (writeTable / createTableSql), then checks each one three ways:
#   1. sqlite3 PRAGMA integrity_check == "ok"            (strongest gate)
#   2. sqlite3 SELECT * matches the intended rows         (round-trip OUT)
#   3. the existing Medaka reader decodes the SAME rows   (round-trip SELF —
#      proves the writer is the exact inverse of the trusted reader)
#
# Schemas tested:
#   Schema 1: users — WITH INTEGER PRIMARY KEY (id) + NULL column (age)
#   Schema 2: kv    — WITHOUT IPK (auto rowid), text key + nullable int value
#   Schema 3: blobs — WITH BLOB column (binary data + NULL blob)
#
# Usage:
#   sqlite/test/writer_api_oracle.sh            # build, write dbs, verify all gates
#   sqlite/test/writer_api_oracle.sh --capture  # (re)write the golden files
#
# Requires: sqlite3 on PATH; the Medaka tree built (`make medaka`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

GOLDEN="$HERE/writer_api.golden"
TMPDIR_LOC="$(mktemp -d)"
OUT="$(mktemp)"

MEDAKA="$ROOT/medaka"
WRITER="$TMPDIR_LOC/writer_api_probe"
READER="$TMPDIR_LOC/sqlite_reader"
export MEDAKA_ROOT="$ROOT"
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

# 1. Build the Medaka writer_api_demo binary.
"$MEDAKA" build sqlite/writer_api_demo.mdk -o "$WRITER" >/dev/null

# 2. Build the Medaka reader binary (for the self round-trip gate).
"$MEDAKA" build sqlite/main.mdk -o "$READER" >/dev/null

# 3. Helper: write one database + produce one section of the report.
write_section () {
  local cmd="$1"
  local db="$2"
  rm -f "$db"
  "$WRITER" "$cmd" "$db" >/dev/null
}

DB_USERS="$TMPDIR_LOC/users.db"
DB_KV="$TMPDIR_LOC/kv.db"
DB_BLOB="$TMPDIR_LOC/blob.db"
DB_REALS="$TMPDIR_LOC/reals.db"

write_section users "$DB_USERS"
write_section kv    "$DB_KV"
write_section blob  "$DB_BLOB"
write_section reals "$DB_REALS"

# 4. Produce the combined report.
{
  echo "### schema: users (INTEGER PRIMARY KEY + NULL)"
  echo "# integrity_check"
  sqlite3 "$DB_USERS" "PRAGMA integrity_check;"
  echo "# schema"
  sqlite3 "$DB_USERS" "SELECT type, name, rootpage FROM sqlite_master;"
  echo "# sqlite3 SELECT"
  sqlite3 "$DB_USERS" "SELECT * FROM users ORDER BY rowid;"
  echo "# medaka reader"
  "$READER" "$DB_USERS" users

  echo ""
  echo "### schema: kv (no IPK, auto rowid)"
  echo "# integrity_check"
  sqlite3 "$DB_KV" "PRAGMA integrity_check;"
  echo "# schema"
  sqlite3 "$DB_KV" "SELECT type, name, rootpage FROM sqlite_master;"
  echo "# sqlite3 SELECT"
  sqlite3 "$DB_KV" "SELECT * FROM kv ORDER BY rowid;"
  echo "# medaka reader"
  "$READER" "$DB_KV" kv

  echo ""
  echo "### schema: blobs (BLOB column)"
  echo "# integrity_check"
  sqlite3 "$DB_BLOB" "PRAGMA integrity_check;"
  echo "# schema"
  sqlite3 "$DB_BLOB" "SELECT type, name, rootpage FROM sqlite_master;"
  echo "# sqlite3 SELECT (id, blob length)"
  sqlite3 "$DB_BLOB" "SELECT id, length(data) FROM blobs ORDER BY rowid;"
  echo "# medaka reader"
  "$READER" "$DB_BLOB" blobs

  echo ""
  echo "### schema: reals (REAL column)"
  echo "# integrity_check"
  sqlite3 "$DB_REALS" "PRAGMA integrity_check;"
  echo "# schema"
  sqlite3 "$DB_REALS" "SELECT type, name, rootpage FROM sqlite_master;"
  echo "# sqlite3 SELECT"
  sqlite3 "$DB_REALS" "SELECT * FROM reals ORDER BY rowid;"
  echo "# medaka reader"
  "$READER" "$DB_REALS" reals
} > "$OUT"

if [ "${1:-}" = "--capture" ]; then
  cp "$OUT" "$GOLDEN"
  echo "captured golden -> $GOLDEN"
  cat "$GOLDEN"
  exit 0
fi

fail=0

# -----------------------------------------------------------------------
# Schema 1: users — WITH INTEGER PRIMARY KEY + NULL
# -----------------------------------------------------------------------

echo "=== Schema 1: users (INTEGER PRIMARY KEY + NULL age) ==="

echo "--- Gate 1a: integrity_check ---"
IC="$(sqlite3 "$DB_USERS" "PRAGMA integrity_check;")"
if [ "$IC" = "ok" ]; then
  echo "OK: integrity_check = ok"
else
  echo "FAIL: integrity_check = $IC"
  fail=1
fi

echo "--- Gate 1b: sqlite3 SELECT vs intended rows ---"
INTENDED_USERS="$(mktemp)"
cat > "$INTENDED_USERS" <<'EOF'
1|Alice|30
2|Bob|
5|Carol|-5
10|Dave|1000000
EOF
SEL_USERS="$(mktemp)"
sqlite3 "$DB_USERS" "SELECT * FROM users ORDER BY rowid;" > "$SEL_USERS"
if diff -u "$INTENDED_USERS" "$SEL_USERS"; then
  echo "OK: sqlite3 SELECT matches intended (users)"
else
  echo "FAIL: sqlite3 SELECT differs from intended (users)"
  fail=1
fi

echo "--- Gate 1c: Medaka reader self round-trip ---"
RD_USERS="$(mktemp)"
"$READER" "$DB_USERS" users > "$RD_USERS"
if diff -u "$INTENDED_USERS" "$RD_USERS"; then
  echo "OK: Medaka reader matches intended (users)"
else
  echo "FAIL: Medaka reader differs from intended (users)"
  fail=1
fi

# -----------------------------------------------------------------------
# Schema 2: kv — no IPK (auto rowid)
# -----------------------------------------------------------------------

echo ""
echo "=== Schema 2: kv (no IPK, auto rowid) ==="

echo "--- Gate 2a: integrity_check ---"
IC_KV="$(sqlite3 "$DB_KV" "PRAGMA integrity_check;")"
if [ "$IC_KV" = "ok" ]; then
  echo "OK: integrity_check = ok"
else
  echo "FAIL: integrity_check = $IC_KV"
  fail=1
fi

echo "--- Gate 2b: sqlite3 SELECT vs intended rows ---"
INTENDED_KV="$(mktemp)"
cat > "$INTENDED_KV" <<'EOF'
alpha|1
beta|42
gamma|
delta|-7
EOF
SEL_KV="$(mktemp)"
sqlite3 "$DB_KV" "SELECT * FROM kv ORDER BY rowid;" > "$SEL_KV"
if diff -u "$INTENDED_KV" "$SEL_KV"; then
  echo "OK: sqlite3 SELECT matches intended (kv)"
else
  echo "FAIL: sqlite3 SELECT differs from intended (kv)"
  fail=1
fi

echo "--- Gate 2c: Medaka reader self round-trip ---"
RD_KV="$(mktemp)"
"$READER" "$DB_KV" kv > "$RD_KV"
if diff -u "$INTENDED_KV" "$RD_KV"; then
  echo "OK: Medaka reader matches intended (kv)"
else
  echo "FAIL: Medaka reader differs from intended (kv)"
  fail=1
fi

# -----------------------------------------------------------------------
# Schema 3: blobs — BLOB column
# -----------------------------------------------------------------------

echo ""
echo "=== Schema 3: blobs (BLOB column) ==="

echo "--- Gate 3a: integrity_check ---"
IC_BLOB="$(sqlite3 "$DB_BLOB" "PRAGMA integrity_check;")"
if [ "$IC_BLOB" = "ok" ]; then
  echo "OK: integrity_check = ok"
else
  echo "FAIL: integrity_check = $IC_BLOB"
  fail=1
fi

echo "--- Gate 3b: sqlite3 SELECT id + blob length vs intended ---"
INTENDED_BLOB="$(mktemp)"
cat > "$INTENDED_BLOB" <<'EOF'
1|5
2|4
3|
EOF
SEL_BLOB="$(mktemp)"
sqlite3 "$DB_BLOB" "SELECT id, length(data) FROM blobs ORDER BY rowid;" > "$SEL_BLOB"
if diff -u "$INTENDED_BLOB" "$SEL_BLOB"; then
  echo "OK: sqlite3 SELECT matches intended (blobs)"
else
  echo "FAIL: sqlite3 SELECT differs from intended (blobs)"
  fail=1
fi

echo "--- Gate 3c: Medaka reader self round-trip (blobs shown as <blob>, NULL as empty) ---"
RD_BLOB="$(mktemp)"
"$READER" "$DB_BLOB" blobs > "$RD_BLOB"
INTENDED_BLOB_RD="$(mktemp)"
# cellToString renders CBlob as "<blob>" and CNull as "".
cat > "$INTENDED_BLOB_RD" <<'EOF'
1|<blob>
2|<blob>
3|
EOF
if diff -u "$INTENDED_BLOB_RD" "$RD_BLOB"; then
  echo "OK: Medaka reader matches intended (blobs)"
else
  echo "FAIL: Medaka reader differs from intended (blobs)"
  fail=1
fi

# -----------------------------------------------------------------------
# Schema 4: reals — REAL (float) column
# -----------------------------------------------------------------------

echo ""
echo "=== Schema 4: reals (REAL column) ==="

echo "--- Gate 4a: integrity_check ---"
IC_REALS="$(sqlite3 "$DB_REALS" "PRAGMA integrity_check;")"
if [ "$IC_REALS" = "ok" ]; then
  echo "OK: integrity_check = ok"
else
  echo "FAIL: integrity_check = $IC_REALS"
  fail=1
fi

echo "--- Gate 4b: sqlite3 SELECT vs intended rows ---"
INTENDED_REALS="$(mktemp)"
cat > "$INTENDED_REALS" <<'EOF'
1|3.14
2|0.0
3|-2.718
4|9999999.9
5|
EOF
SEL_REALS="$(mktemp)"
sqlite3 "$DB_REALS" "SELECT * FROM reals ORDER BY rowid;" > "$SEL_REALS"
if diff -u "$INTENDED_REALS" "$SEL_REALS"; then
  echo "OK: sqlite3 SELECT matches intended (reals)"
else
  echo "FAIL: sqlite3 SELECT differs from intended (reals)"
  fail=1
fi

echo "--- Gate 4c: Medaka reader self round-trip ---"
RD_REALS="$(mktemp)"
"$READER" "$DB_REALS" reals > "$RD_REALS"
if diff -u "$INTENDED_REALS" "$RD_REALS"; then
  echo "OK: Medaka reader matches intended (reals)"
else
  echo "FAIL: Medaka reader differs from intended (reals)"
  fail=1
fi

# -----------------------------------------------------------------------
# Full report golden
# -----------------------------------------------------------------------

echo ""
echo "=== Gate 5: combined report vs committed golden ==="
if diff -u "$GOLDEN" "$OUT"; then
  echo "OK: report matches golden"
else
  echo "FAIL: report differs from golden"
  fail=1
fi

exit "$fail"
