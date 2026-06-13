#!/bin/sh
# Batched variant of diff_selfhost_desugar.sh — amortizes the per-process
# module-load cost.  The original ran `medaka run desugar_main.mdk <file>` once
# per corpus file (~92 processes), each re-loading the self-hosted
# parser/desugar/sexp modules; that fixed per-process cost dominated once the
# interpreter env-lookup win made per-file desugaring cheap.
#
# This runs selfhost/entries/desugar_batch.mdk ONCE over the whole corpus (modules loaded
# once), splits the delimited output per file in a single awk pass, and compares
# each section against dev/astdump.exe --desugar.  FLOAT literal text is
# normalized away (OCaml %g vs floatToString), like the original.
#
# Usage:  sh test/diff_selfhost_desugar_batch.sh [file.mdk ...]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/desugar_batch"
[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

norm() { sed 's/(LFloat [^)]*)/(LFloat)/g'; }

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$ROOT/stdlib/*.mdk $ROOT/test/diff_fixtures/*.mdk $ROOT/test/parse_fixtures/*.mdk $ROOT/selfhost/*.mdk"
fi

# Stable list of existing files.
list=""
for f in $files; do [ -f "$f" ] && list="$list $f"; done

ALL="$("$RUN" $list 2>/dev/null | sed '$ s/()$//; ${/^$/d;}')"  # strip native Unit "()" tail

# Split the combined output into one file per section in a SINGLE awk pass
# (keyed by a path->filename transform both sides compute), instead of
# re-scanning the whole output once per file (quadratic in corpus size).
SECDIR="$(mktemp -d)"
trap 'rm -rf "$SECDIR"' EXIT
printf '%s' "$ALL" | awk -v dir="$SECDIR" '
  /^===SELFHOST-DESUGAR=== /{ p=$2; gsub(/[\/.]/,"_",p); out=dir "/" p; next }
  out { print > out }
'

pass=0; fail=0
for f in $list; do
  name="$(basename "$f")"
  golden="${f%.mdk}.desugar.golden"
  if [ -f "$golden" ]; then expected="$(norm < "$golden")"; else expected=""; fi
  key="$(printf '%s' "$f" | tr '/.' '__')"
  if [ -f "$SECDIR/$key" ]; then actual="$(norm < "$SECDIR/$key")"; else actual=""; fi
  if [ "$expected" = "$actual" ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done

printf '\n%d matched, %d differing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
