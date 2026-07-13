#!/usr/bin/env bash
# Differential oracle for the Medaka SQLite MULTI-TABLE write path
# (writer.mdk `writeTables` → dbwriter.mdk `buildDatabaseMulti`).
#
# Builds ONE `.sqlite` file containing THREE tables FROM SCRATCH with the Medaka
# writer, mixing layouts in a single file:
#   * users(id INTEGER PRIMARY KEY, name TEXT)  — single leaf page  (rootpage 2)
#   * big(id INTEGER PRIMARY KEY, val TEXT)      — N rows → interior root over
#                                                 >=3 leaf pages    (rootpage 3)
#   * kv(k TEXT, v INTEGER)                       — single leaf, NO ipk
# then checks it the same ways as the single/multi-page writer oracles:
#   1. sqlite3 PRAGMA integrity_check == "ok"        (strongest gate; any wrong
#      rootpage / page offset fails this instantly)
#   2. sqlite_master shows all 3 tables with DISTINCT correct rootpages, and
#      the page layout is the expected mixed shape (single-leaf + interior).
#   3. sqlite3 SELECT * / count(*) per table match the intended rows.
#   4. the Medaka reader round-trips EVERY table.
#   5. a small committed combined-report golden.
#
# Usage:
#   sqlite/test/multitable_write_oracle.sh            # build, write db, verify
#   sqlite/test/multitable_write_oracle.sh --capture  # (re)write the golden
#
# Requires: sqlite3 + python3 on PATH; the Medaka tree built (`make medaka`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

# big-table row count: forces an interior root over >=3 leaf pages.
N=700

GOLDEN="$HERE/multitable_write.golden"
DB="$(mktemp -d)/multitable_write.db"
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
WRITER="$BINDIR/sqlite_mtwriter"
READER="$BINDIR/sqlite_reader"
export MEDAKA_ROOT="$ROOT"
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

# 1. Build the Medaka multi-table writer demo binary.
"$MEDAKA" build sqlite/multitable_write_demo.mdk -o "$WRITER" >/dev/null

# 2. Build the Medaka reader binary (for the self round-trip gate).
"$MEDAKA" build sqlite/main.mdk -o "$READER" >/dev/null

# 3. Generate the multi-table database WITH THE MEDAKA WRITER (no sqlite3).
rm -f "$DB"
"$WRITER" "$N" "$DB" >/dev/null

# 4. Compute a structural summary of the on-disk pages.
LAYOUT="$(python3 -c "
import struct
d = open('$DB','rb').read()
ps = struct.unpack('>H', d[16:18])[0]
if ps == 1: ps = 65536
pages = len(d)//ps
def ptype(p):
    return d[100] if p == 0 else d[p*ps]
interior = sum(1 for p in range(1, pages) if ptype(p) == 5)
leaves   = sum(1 for p in range(1, pages) if ptype(p) == 13)
print('pages=%d interior=%d leaves=%d types=%s' % (pages, interior, leaves, ''.join(str(ptype(p)) for p in range(pages))))
")"

# 5. Produce the combined report.
{
  echo "# integrity_check"
  sqlite3 "$DB" "PRAGMA integrity_check;"
  echo "# schema"
  sqlite3 "$DB" "SELECT type, name, rootpage FROM sqlite_master ORDER BY rootpage;"
  echo "# page layout"
  echo "$LAYOUT"
  echo "# counts"
  echo "users=$(sqlite3 "$DB" "SELECT count(*) FROM users;")"
  echo "big=$(sqlite3 "$DB" "SELECT count(*) FROM big;")"
  echo "kv=$(sqlite3 "$DB" "SELECT count(*) FROM kv;")"
  echo "# users"
  sqlite3 "$DB" "SELECT * FROM users ORDER BY id;"
  echo "# kv"
  sqlite3 "$DB" "SELECT * FROM kv ORDER BY rowid;"
  echo "# big first/last"
  sqlite3 "$DB" "SELECT * FROM big ORDER BY id LIMIT 2;"
  sqlite3 "$DB" "SELECT * FROM big ORDER BY id DESC LIMIT 2;" | sort -n
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
if [ "$IC" = "ok" ]; then echo "OK: integrity_check = ok"; else echo "FAIL: integrity_check = $IC"; fail=1; fi

# Gate 2: three tables, distinct rootpages, mixed layout (interior + single leaves).
echo "=== Gate 2: 3 tables, distinct rootpages, mixed layout ==="
echo "layout: $LAYOUT"
ROOTPAGES="$(sqlite3 "$DB" "SELECT rootpage FROM sqlite_master ORDER BY rootpage;" | tr '\n' ' ')"
NTAB="$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type='table';")"
NDISTINCT="$(sqlite3 "$DB" "SELECT count(DISTINCT rootpage) FROM sqlite_master WHERE type='table';")"
INTERIOR="$(echo "$LAYOUT" | sed -n 's/.*interior=\([0-9]*\).*/\1/p')"
LEAVES="$(echo "$LAYOUT"   | sed -n 's/.*leaves=\([0-9]*\).*/\1/p')"
if [ "$NTAB" = "3" ] && [ "$NDISTINCT" = "3" ] && [ "$INTERIOR" -ge 1 ] && [ "$LEAVES" -ge 5 ]; then
  echo "OK: 3 tables, distinct rootpages ($ROOTPAGES), >=1 interior + >=5 leaves"
else
  echo "FAIL: ntab=$NTAB distinct=$NDISTINCT interior=$INTERIOR leaves=$LEAVES rootpages=$ROOTPAGES"
  fail=1
fi

# Gate 3: sqlite3 SELECT / count per table match intended.
echo "=== Gate 3: sqlite3 SELECT vs intended (per table) ==="
INTENDED_BIG="$(mktemp)"
python3 -c "
for i in range(1, $N + 1):
    print('%d|item_%d' % (i, i))
" > "$INTENDED_BIG"
g3=0
[ "$(sqlite3 "$DB" "SELECT count(*) FROM users;")" = "3" ] || { echo "FAIL users count"; g3=1; }
[ "$(sqlite3 "$DB" "SELECT count(*) FROM kv;")"    = "3" ] || { echo "FAIL kv count"; g3=1; }
[ "$(sqlite3 "$DB" "SELECT count(*) FROM big;")"   = "$N" ] || { echo "FAIL big count"; g3=1; }
diff -q <(printf '1|alice\n2|bob\n3|carol\n')   <(sqlite3 "$DB" "SELECT * FROM users ORDER BY id;")  >/dev/null || { echo "FAIL users rows"; g3=1; }
diff -q <(printf 'one|1\ntwo|2\nthree|3\n')      <(sqlite3 "$DB" "SELECT * FROM kv ORDER BY rowid;") >/dev/null || { echo "FAIL kv rows"; g3=1; }
diff -q "$INTENDED_BIG" <(sqlite3 "$DB" "SELECT * FROM big ORDER BY id;") >/dev/null || { echo "FAIL big rows"; g3=1; }
if [ "$g3" = "0" ]; then echo "OK: sqlite3 SELECT matches intended for users/big/kv"; else fail=1; fi

# Gate 4: Medaka reader round-trips every table.
echo "=== Gate 4: Medaka reader self round-trip (per table) ==="
g4=0
diff -q <(printf '1|alice\n2|bob\n3|carol\n') <("$READER" "$DB" users) >/dev/null || { echo "FAIL reader users"; g4=1; }
diff -q <(printf 'one|1\ntwo|2\nthree|3\n')    <("$READER" "$DB" kv)    >/dev/null || { echo "FAIL reader kv"; g4=1; }
diff -q "$INTENDED_BIG" <("$READER" "$DB" big) >/dev/null || { echo "FAIL reader big"; g4=1; }
if [ "$g4" = "0" ]; then echo "OK: Medaka reader round-trips users/big/kv (writer == inverse of reader)"; else fail=1; fi

# Gate 5: combined report matches the committed golden.
echo "=== Gate 5: combined report vs committed golden ==="
if diff -u "$GOLDEN" "$OUT"; then echo "OK: report matches golden"; else echo "FAIL: report differs from golden"; fail=1; fi

exit "$fail"
