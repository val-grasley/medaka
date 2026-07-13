#!/usr/bin/env bash
# Differential oracle for the ROWID-FAITHFUL write path (stage 1 of SQLite
# row-mutation).  Proves a read→rewrite of a NON-IPK table preserves the
# original rowids INCLUDING GAPS, instead of renumbering survivors to 1..N.
#
# The bug this fixes: the old auto-rowid writer (`dbwriter.mdk` rowidFor None →
# 1..N) collapsed a non-IPK table with rowids 1,3,4 to 1,2,3 on rewrite.  The
# new explicit-rowid path (`buildDatabaseMultiExplicit`, driven here by
# `rowid_roundtrip_demo.mdk`) round-trips the gap faithfully.
#
# Pipeline:
#   1. Seed a db with sqlite3: a NON-IPK table `kv` with a rowid GAP (1,3,4) and
#      an IPK table `users` with a non-contiguous IPK (1,5,9).
#   2. Round-trip the WHOLE file with the Medaka explicit-rowid writer
#      (`rowid_roundtrip_demo <in> <out>`), reusing each table's stored CREATE
#      text + IPK index — the identity read→rewrite-all mutation pipeline.
#   3. Verify with sqlite3:
#      * non-IPK rowids preserved with the GAP (1,3,4) — NOT 1,2,3 (the bug).
#      * IPK rowids preserved (1,5,9).
#      * column values preserved.
#      * PRAGMA integrity_check == ok.
#   4. Reader self round-trip (the Medaka reader re-reads the rewritten file).
#   5. A committed combined-report golden.
#
# Usage:
#   sqlite/test/rowid_roundtrip_oracle.sh            # build, round-trip, verify
#   sqlite/test/rowid_roundtrip_oracle.sh --capture  # (re)write the golden
#
# Requires: sqlite3 on PATH; the Medaka tree built (`make medaka`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

GOLDEN="$HERE/rowid_roundtrip.golden"
TMP="$(mktemp -d)"
SRC="$TMP/src.db"
DST="$TMP/dst.db"
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
PROBE="$BINDIR/sqlite_rowid_rt"
READER="$BINDIR/sqlite_reader"
export MEDAKA_ROOT="$ROOT"
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

# 1. Build the Medaka round-trip probe + reader binaries.
"$MEDAKA" build sqlite/rowid_roundtrip_demo.mdk -o "$PROBE" >/dev/null
"$MEDAKA" build sqlite/main.mdk -o "$READER" >/dev/null

# 2. Seed the source db with sqlite3: a non-IPK gap + an IPK gap.
rm -f "$SRC" "$DST"
sqlite3 "$SRC" "
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO users(id,name) VALUES (1,'alice'),(5,'bob'),(9,'carol');
CREATE TABLE kv(k TEXT, v INTEGER);
INSERT INTO kv(rowid,k,v) VALUES (1,'a',10),(3,'b',30),(4,'c',40);
"

SRC_KV_ROWIDS="$(sqlite3 "$SRC" "SELECT rowid FROM kv ORDER BY rowid;" | tr '\n' ',' )"
SRC_USR_ROWIDS="$(sqlite3 "$SRC" "SELECT rowid FROM users ORDER BY rowid;" | tr '\n' ',' )"

# 3. Round-trip the whole file with the Medaka explicit-rowid writer.
"$PROBE" "$SRC" "$DST" >/dev/null

DST_KV_ROWIDS="$(sqlite3 "$DST" "SELECT rowid FROM kv ORDER BY rowid;" | tr '\n' ',' )"
DST_USR_ROWIDS="$(sqlite3 "$DST" "SELECT rowid FROM users ORDER BY rowid;" | tr '\n' ',' )"

# 4. Combined report.
{
  echo "# integrity_check"
  sqlite3 "$DST" "PRAGMA integrity_check;"
  echo "# kv rowids (src -> dst)"
  echo "src=$SRC_KV_ROWIDS dst=$DST_KV_ROWIDS"
  echo "# users rowids (src -> dst)"
  echo "src=$SRC_USR_ROWIDS dst=$DST_USR_ROWIDS"
  echo "# kv rows"
  sqlite3 "$DST" "SELECT rowid,k,v FROM kv ORDER BY rowid;"
  echo "# users rows"
  sqlite3 "$DST" "SELECT rowid,id,name FROM users ORDER BY rowid;"
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
IC="$(sqlite3 "$DST" "PRAGMA integrity_check;")"
if [ "$IC" = "ok" ]; then echo "OK: integrity_check = ok"; else echo "FAIL: integrity_check = $IC"; fail=1; fi

# Gate 2: non-IPK rowid GAP preserved (the bug this fixes).
echo "=== Gate 2: non-IPK rowid gap preserved (1,3,4) ==="
echo "kv rowids: src=$SRC_KV_ROWIDS  dst=$DST_KV_ROWIDS"
if [ "$DST_KV_ROWIDS" = "1,3,4," ]; then
  echo "OK: kv rowids preserved with gap (NOT renumbered to 1,2,3)"
else
  echo "FAIL: kv rowids = $DST_KV_ROWIDS (expected 1,3,4,)"
  fail=1
fi

# Gate 3: IPK rowids preserved (1,5,9) — byte-faithful IPK path.
echo "=== Gate 3: IPK rowids preserved (1,5,9) ==="
echo "users rowids: src=$SRC_USR_ROWIDS  dst=$DST_USR_ROWIDS"
if [ "$DST_USR_ROWIDS" = "1,5,9," ]; then
  echo "OK: users IPK rowids preserved"
else
  echo "FAIL: users rowids = $DST_USR_ROWIDS (expected 1,5,9,)"
  fail=1
fi

# Gate 4: column values preserved (sqlite3 SELECT).
echo "=== Gate 4: column values preserved ==="
g4=0
diff -q <(printf '1|a|10\n3|b|30\n4|c|40\n')        <(sqlite3 "$DST" "SELECT rowid,k,v FROM kv ORDER BY rowid;")        >/dev/null || { echo "FAIL kv values"; g4=1; }
diff -q <(printf '1|alice\n5|bob\n9|carol\n')        <(sqlite3 "$DST" "SELECT * FROM users ORDER BY id;")               >/dev/null || { echo "FAIL users values"; g4=1; }
if [ "$g4" = "0" ]; then echo "OK: kv + users values preserved"; else fail=1; fi

# Gate 5: Medaka reader self round-trips the rewritten file.
echo "=== Gate 5: Medaka reader self round-trip ==="
g5=0
diff -q <(printf 'a|10\nb|30\nc|40\n')   <("$READER" "$DST" kv)    >/dev/null || { echo "FAIL reader kv"; g5=1; }
diff -q <(printf '1|alice\n5|bob\n9|carol\n') <("$READER" "$DST" users) >/dev/null || { echo "FAIL reader users"; g5=1; }
if [ "$g5" = "0" ]; then echo "OK: reader round-trips kv + users"; else fail=1; fi

# Gate 6: combined report matches the committed golden.
echo "=== Gate 6: combined report vs committed golden ==="
if diff -u "$GOLDEN" "$OUT"; then echo "OK: report matches golden"; else echo "FAIL: report differs from golden"; fail=1; fi

exit "$fail"
