#!/bin/sh
# Batched variant of diff_compiler_mark.sh — PROTOTYPE for prelude caching.
# Runs compiler/entries/mark_batch.mdk ONCE over the whole corpus (prelude parsed once),
# splits the delimited output per file, and compares each section LITERALLY
# against its golden — no float normalization (one deterministic renderer now).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/mark_batch"
CORE="$ROOT/stdlib/core.mdk"
[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$ROOT/stdlib/*.mdk $ROOT/test/diff_fixtures/*.mdk $ROOT/test/parse_fixtures/*.mdk $ROOT/compiler/frontend/*.mdk $ROOT/compiler/types/*.mdk $ROOT/compiler/ir/*.mdk $ROOT/compiler/backend/*.mdk $ROOT/compiler/eval/*.mdk $ROOT/compiler/driver/*.mdk $ROOT/compiler/tools/*.mdk $ROOT/compiler/support/*.mdk"
fi

# Expand to a stable list of existing files.
list=""
for f in $files; do [ -f "$f" ] && list="$list $f"; done

ALL="$("$RUN" "$CORE" $list 2>/dev/null | sed '$ s/()$//; ${/^$/d;}')"  # strip native Unit "()" tail

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
  golden="${f%.mdk}.mark.golden"
  if [ -f "$golden" ]; then expected="$(cat "$golden")"; else expected=""; fi
  key="$(printf '%s' "$f" | tr '/.' '__')"
  if [ -f "$SECDIR/$key" ]; then actual="$(cat "$SECDIR/$key")"; else actual=""; fi
  if [ "$expected" = "$actual" ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done

printf '\n%d matched, %d differing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
