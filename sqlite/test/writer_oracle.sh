#!/usr/bin/env bash
# Differential oracle for the Medaka SQLite WRITE-path library (dbwriter.mdk).
#
# Builds a fresh single-table .db FROM SCRATCH with the Medaka writer, then
# checks it three ways:
#   1. sqlite3 PRAGMA integrity_check == "ok"            (strongest gate)
#   2. sqlite3 SELECT * matches the intended rows         (round-trip OUT)
#   3. the existing Medaka reader decodes the SAME rows   (round-trip SELF —
#      proves the writer is the exact inverse of the trusted reader)
#
# The binary .db is regenerated each run (never committed); only this script
# and the captured goldens live in git.
#
# Table written (single table-leaf root pages, one data page):
#   CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, age INTEGER)
#   rows: varied integer widths, a NULL age, a negative age, an i8 boundary,
#   and non-contiguous INTEGER PRIMARY KEY rowids (1,2,3,7,42).
#
# Usage:
#   sqlite/test/writer_oracle.sh            # build, write db, verify all gates
#   sqlite/test/writer_oracle.sh --capture  # (re)write the golden files
#
# Requires: sqlite3 on PATH; the Medaka tree built (`make medaka`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

GOLDEN="$HERE/writer.golden"
DB="$(mktemp -d)/writer.db"
OUT="$(mktemp)"

MEDAKA="$ROOT/medaka"
# Scratch binaries live in a PER-PROCESS temp dir, never at the repo root.
#
# These used to run `medaka build sqlite/main.mdk` with NO `-o`, which emits the binary
# as ./<entry> at the REPO ROOT, and then `mv`d it to a FIXED path ($ROOT/sqlite_reader).
# Both halves are a race: two of these oracles running concurrently clobbered each
# other's ./main and shared one sqlite_reader. Serially all 22 passed; under run_gates'
# parallel pool, 2 failed — and which 2 varied. (Same bug class, and same fix, as the
# `medaka build` scratch-path collision in AGENTS.md: the only correct answer is a
# per-process temp dir. Anything keyed on the entry name is a trap.)
BINDIR="$(mktemp -d)"
trap 'rm -rf "$BINDIR"' EXIT
WRITER="$BINDIR/sqlite_writer"
READER="$BINDIR/sqlite_reader"
export MEDAKA_ROOT="$ROOT"
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

# 1. Build the Medaka writer binary from sqlite/writer_demo.mdk, straight into $BINDIR.
# (`-o` is load-bearing — see the $BINDIR note above.)
"$MEDAKA" build sqlite/writer_demo.mdk -o "$WRITER" >/dev/null

# 2. Build the Medaka reader binary from sqlite/main.mdk (for the self gate).
"$MEDAKA" build sqlite/main.mdk -o "$READER" >/dev/null

# 3. Generate the database WITH THE MEDAKA WRITER (from scratch — no sqlite3).
rm -f "$DB"
"$WRITER" "$DB" >/dev/null

# 4. Produce the combined report.
{
  echo "# integrity_check"
  sqlite3 "$DB" "PRAGMA integrity_check;"
  echo "# schema"
  sqlite3 "$DB" "SELECT type, name, rootpage FROM sqlite_master;"
  echo "# sqlite3 SELECT"
  sqlite3 "$DB" "SELECT * FROM users ORDER BY rowid;"
  echo "# medaka reader"
  "$READER" "$DB" users
} > "$OUT"

if [ "${1:-}" = "--capture" ]; then
  cp "$OUT" "$GOLDEN"
  echo "captured golden -> $GOLDEN"
  cat "$GOLDEN"
  exit 0
fi

fail=0

# Gate 1: integrity_check ok.
echo "=== Gate 1: PRAGMA integrity_check ==="
IC="$(sqlite3 "$DB" "PRAGMA integrity_check;")"
if [ "$IC" = "ok" ]; then
  echo "OK: integrity_check = ok"
else
  echo "FAIL: integrity_check = $IC"
  fail=1
fi

# Gate 2: sqlite3 SELECT matches intended rows.
INTENDED="$(mktemp)"
cat > "$INTENDED" <<'EOF'
1|Alice|30
2|Bob|
3|Carol|-5
7|Dave|1000000
42|Eve|127
EOF
echo "=== Gate 2: sqlite3 SELECT vs intended rows ==="
SEL="$(mktemp)"
sqlite3 "$DB" "SELECT * FROM users ORDER BY rowid;" > "$SEL"
if diff -u "$INTENDED" "$SEL"; then
  echo "OK: sqlite3 SELECT matches intended"
else
  echo "FAIL: sqlite3 SELECT differs from intended"
  fail=1
fi

# Gate 3: Medaka reader decodes the same rows (self round-trip).
echo "=== Gate 3: Medaka reader self round-trip ==="
RD="$(mktemp)"
"$READER" "$DB" users > "$RD"
if diff -u "$INTENDED" "$RD"; then
  echo "OK: Medaka reader matches intended (writer == inverse of reader)"
else
  echo "FAIL: Medaka reader differs from intended"
  fail=1
fi

# Gate 4: full combined report matches the committed golden.
echo "=== Gate 4: combined report vs committed golden ==="
if diff -u "$GOLDEN" "$OUT"; then
  echo "OK: report matches golden"
else
  echo "FAIL: report differs from golden"
  fail=1
fi

exit "$fail"
