#!/bin/sh
# Batched variant of diff_selfhost_mark.sh — PROTOTYPE for prelude caching.
# Runs selfhost/mark_batch.mdk ONCE over the whole corpus (prelude parsed once),
# splits the delimited output per file, and compares each against astdump --mark.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
REF="$ROOT/_build/default/dev/astdump.exe"
BATCH="$ROOT/selfhost/mark_batch.mdk"
CORE="$ROOT/stdlib/core.mdk"
[ -x "$MAIN" ] || { echo "build first: dune build --root ."; exit 2; }
[ -x "$REF" ]  || { echo "build first: dune build --root . dev/astdump.exe"; exit 2; }

norm() { sed 's/(LFloat [^)]*)/(LFloat)/g'; }

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$ROOT/stdlib/*.mdk $ROOT/test/diff_fixtures/*.mdk $ROOT/test/parse_fixtures/*.mdk $ROOT/selfhost/*.mdk"
fi

# Expand to a stable list of existing files.
list=""
for f in $files; do [ -f "$f" ] && list="$list $f"; done

ALL="$("$MAIN" run "$BATCH" "$CORE" $list 2>/dev/null)"

# Split the combined output into one file per section in a SINGLE awk pass
# (keyed by a path->filename transform both sides compute), instead of
# re-scanning the whole output once per corpus file — the latter is quadratic in
# corpus size (was ~2.9s of the harness; the marker line is `===SELFHOST-FIX===
# <fullpath>`).
SECDIR="$(mktemp -d)"
trap 'rm -rf "$SECDIR"' EXIT
printf '%s' "$ALL" | awk -v dir="$SECDIR" '
  /^===SELFHOST-FIX=== /{ p=$2; gsub(/[\/.]/,"_",p); out=dir "/" p; next }
  out { print > out }
'

pass=0; fail=0
for f in $list; do
  name="$(basename "$f")"
  expected="$("$REF" --mark "$f" 2>/dev/null | norm)"
  key="$(printf '%s' "$f" | tr '/.' '__')"
  if [ -f "$SECDIR/$key" ]; then actual="$(norm < "$SECDIR/$key")"; else actual=""; fi
  if [ "$expected" = "$actual" ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done

printf '\n%d matched, %d differing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
