#!/usr/bin/env bash
# Differential oracle for the Medaka SQLite MULTI-PAGE write path (dbwriter.mdk).
#
# Builds a fresh single-table .db FROM SCRATCH with the Medaka writer whose row
# count forces a table-interior (0x05) root page over ≥3 leaf pages, then checks
# it the same three ways as the single-page writer_oracle:
#   1. sqlite3 PRAGMA integrity_check == "ok"            (strongest gate; any
#      wrong offset/pointer in the interior tree fails this immediately)
#   2. sqlite3 SELECT * matches the intended rows         (round-trip OUT)
#   3. the existing Medaka reader (which traverses interior pages) decodes the
#      SAME rows                                          (round-trip SELF)
# Plus a structural assertion that the root really is an interior page over ≥3
# leaves, and a small committed combined-report golden.
#
# Table written (interior root → multiple leaf children):
#   CREATE TABLE t(id INTEGER PRIMARY KEY, val TEXT)
#   rows: (1,"item_1") .. (N,"item_N")   — N chosen to span ≥3 leaf pages.
#
# Usage:
#   sqlite/test/multipage_write_oracle.sh            # build, write db, verify all gates
#   sqlite/test/multipage_write_oracle.sh --capture  # (re)write the golden file
#
# Requires: sqlite3 + python3 on PATH; the Medaka tree built (`make medaka`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

# Row count chosen so the table spans ≥3 leaf pages under one interior root.
N=700

GOLDEN="$HERE/multipage_write.golden"
DB="$(mktemp -d)/multipage_write.db"
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
WRITER="$BINDIR/sqlite_mpwriter"
READER="$BINDIR/sqlite_reader"
export MEDAKA_ROOT="$ROOT"
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

# 1. Build the Medaka multi-page writer demo binary.
"$MEDAKA" build sqlite/multipage_write_demo.mdk -o "$WRITER" >/dev/null

# 2. Build the Medaka reader binary (for the self round-trip gate).
"$MEDAKA" build sqlite/main.mdk -o "$READER" >/dev/null

# 3. Generate the database WITH THE MEDAKA WRITER (from scratch — no sqlite3).
rm -f "$DB"
"$WRITER" "$N" "$DB" >/dev/null

# 4. Compute a structural summary of the on-disk b-tree.
LAYOUT="$(python3 -c "
import struct
d = open('$DB','rb').read()
ps = struct.unpack('>H', d[16:18])[0]
if ps == 1: ps = 65536
pages = len(d)//ps
# page 1 has the 100-byte file header before its b-tree header; others start at base.
def ptype(p):
    base = p*ps  # 0-indexed page p -> file offset; page 1 (p=0) type byte is at 100
    return d[100] if p == 0 else d[base]
interior = sum(1 for p in range(1, pages) if ptype(p) == 5)
leaves   = sum(1 for p in range(1, pages) if ptype(p) == 13)
# rootpage of table t -> its page type
print('pages=%d interior=%d leaves=%d rootpage_type=%d' % (pages, interior, leaves, d[ps]))
")"

# 5. Produce the combined report.
{
  echo "# integrity_check"
  sqlite3 "$DB" "PRAGMA integrity_check;"
  echo "# schema"
  sqlite3 "$DB" "SELECT type, name, rootpage FROM sqlite_master;"
  echo "# page layout"
  echo "$LAYOUT"
  echo "# count"
  sqlite3 "$DB" "SELECT count(*) FROM t;"
  echo "# first 3 rows"
  sqlite3 "$DB" "SELECT * FROM t ORDER BY rowid LIMIT 3;"
  echo "# last 3 rows"
  sqlite3 "$DB" "SELECT * FROM t ORDER BY rowid DESC LIMIT 3;" | sort -n
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

# Gate 2: structural — root is an interior page over ≥3 leaves.
echo "=== Gate 2: interior root over >=3 leaves ==="
echo "layout: $LAYOUT"
ROOT_TYPE="$(echo "$LAYOUT" | sed -n 's/.*rootpage_type=\([0-9]*\).*/\1/p')"
LEAF_COUNT="$(echo "$LAYOUT" | sed -n 's/.*leaves=\([0-9]*\).*/\1/p')"
if [ "$ROOT_TYPE" = "5" ] && [ "$LEAF_COUNT" -ge 3 ]; then
  echo "OK: interior (0x05) root over $LEAF_COUNT leaves"
else
  echo "FAIL: expected interior root over >=3 leaves (got type=$ROOT_TYPE leaves=$LEAF_COUNT)"
  fail=1
fi

# Gate 3: sqlite3 SELECT matches intended rows (count + full row set).
echo "=== Gate 3: sqlite3 SELECT vs intended rows ==="
INTENDED="$(mktemp)"
python3 -c "
for i in range(1, $N + 1):
    print('%d|item_%d' % (i, i))
" > "$INTENDED"
SEL="$(mktemp)"
sqlite3 "$DB" "SELECT * FROM t ORDER BY rowid;" > "$SEL"
CNT="$(sqlite3 "$DB" "SELECT count(*) FROM t;")"
if [ "$CNT" = "$N" ] && diff -q "$INTENDED" "$SEL" >/dev/null; then
  echo "OK: sqlite3 SELECT matches intended ($CNT rows)"
else
  echo "FAIL: sqlite3 SELECT differs from intended (count=$CNT)"
  diff -u "$INTENDED" "$SEL" | head -20
  fail=1
fi

# Gate 4: Medaka reader decodes the same rows (self round-trip through interior).
echo "=== Gate 4: Medaka reader self round-trip ==="
RD="$(mktemp)"
"$READER" "$DB" t > "$RD"
if diff -q "$INTENDED" "$RD" >/dev/null; then
  echo "OK: Medaka reader matches intended ($(wc -l < "$RD" | tr -d ' ') rows; writer == inverse of reader)"
else
  echo "FAIL: Medaka reader differs from intended"
  diff -u "$INTENDED" "$RD" | head -20
  fail=1
fi

# Gate 5: combined report matches the committed golden.
echo "=== Gate 5: combined report vs committed golden ==="
if diff -u "$GOLDEN" "$OUT"; then
  echo "OK: report matches golden"
else
  echo "FAIL: report differs from golden"
  fail=1
fi

exit "$fail"
