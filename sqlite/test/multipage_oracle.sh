#!/usr/bin/env bash
# Differential oracle for multi-page B-tree traversal (slice 6 / phase 2).
#
# Generates a table with 2000 rows, forcing a table-interior root page (0x05).
# Reads the table with the Medaka reader and diffs against sqlite3.
#
# Usage:
#   sqlite/test/multipage_oracle.sh            # build reader, generate db, diff
#   sqlite/test/multipage_oracle.sh --capture  # (re)write the golden file
#
# Requires: sqlite3 on PATH, python3 on PATH, the Medaka tree built (`make medaka`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

GOLDEN="$HERE/multipage.golden"
DB="$(mktemp -d)/multipage.db"
OUT="$(mktemp)"

MEDAKA="$ROOT/medaka"
READER="$ROOT/sqlite_reader"
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

# 1. Build the Medaka reader binary.
"$MEDAKA" build sqlite/main.mdk >/dev/null
mv -f "$ROOT/main" "$READER"

# 2. Generate the test database (2000 rows → root page becomes 0x05 interior).
rm -f "$DB"
sqlite3 "$DB" "CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT);"
python3 -c "
import subprocess, sys
rows = ['({}, \"item_{}\")'.format(i, i) for i in range(1, 2001)]
sql = 'INSERT INTO t VALUES ' + ', '.join(rows) + ';'
subprocess.run(['sqlite3', sys.argv[1]], input=sql, text=True, check=True)
" "$DB"

# Sanity: verify root is indeed an interior page.
PAGE_TYPE=$(python3 -c "
import struct
data = open('$DB', 'rb').read()
page_size = struct.unpack('>H', data[16:18])[0]
if page_size == 1: page_size = 65536
# root page of 't' is 2 (written in sqlite_master)
root = struct.unpack('>I', data[28:32])[0]  # not rootpage; get via schema row
import subprocess
r = subprocess.run(['sqlite3', '$DB', \"SELECT rootpage FROM sqlite_master WHERE name='t'\"],
    capture_output=True, text=True)
rp = int(r.stdout.strip())
page_base = (rp - 1) * page_size
print(data[page_base])  # page type byte
")
if [ "$PAGE_TYPE" = "5" ]; then
  echo "Confirmed: root page type=5 (interior)"
else
  echo "Warning: root page type=$PAGE_TYPE (expected 5=interior for 2000 rows)"
fi

# 3. Produce output from the Medaka reader.
"$READER" "$DB" t > "$OUT"

ROW_COUNT=$(wc -l < "$OUT")
echo "Reader returned $ROW_COUNT rows"

if [ "${1:-}" = "--capture" ]; then
  cp "$OUT" "$GOLDEN"
  echo "captured golden -> $GOLDEN"
  exit 0
fi

# 4. Build the expected output from sqlite3 and diff.
ORACLE="$(mktemp)"
sqlite3 "$DB" "SELECT * FROM t" > "$ORACLE"

fail=0
echo "=== Medaka reader vs sqlite3 oracle (multi-page) ==="
if diff -u "$ORACLE" "$OUT"; then
  echo "OK: $ROW_COUNT rows match sqlite3"
else
  echo "FAIL: Medaka reader differs from sqlite3"
  fail=1
fi

if [ -f "$GOLDEN" ]; then
  echo "=== Medaka reader vs committed golden ==="
  if diff -u "$GOLDEN" "$OUT"; then
    echo "OK: matches golden"
  else
    echo "FAIL: differs from golden"
    fail=1
  fi
fi

exit "$fail"
