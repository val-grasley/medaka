#!/bin/sh
# Per-stage performance profiling for the self-hosted pipeline.
# Runs single-file (profile_main.mdk) and multi-module (profile_modules_main.mdk)
# profilers over representative targets, collecting N timed runs and reporting
# per-stage minimums as tables.
#
# Usage:  sh test/profile_compiler.sh [N]
#
# N defaults to 3 (min-of-3 is the standard baseline per PERF-NOTES.md).
# Results go to stdout; progress/debug goes to stderr.
#
# Single-file targets:
#   compiler/frontend/lexer.mdk     — self-contained (no imports); all stages accurate
#   compiler/frontend/parser.mdk    — large file with imports; parse+desugar accurate
#
# Multi-module target:
#   compiler/entries/all_modules_entry.mdk — full 15-module compiler closure;
#       reports parse, load, desugar, mark, typecheck per-stage (no eval)
#
# Output columns: stage, min elapsed, alloc-delta (MB, Gc.allocated_bytes proxy),
# ops (work-unit description).
#
# Format (one table per target):
#   === <file> (min-of-N) ===
#   stage             min       alloc      ops
#   -----             ---       -----      ---
#   parse-prelude   0.228s   1025.7MB   runtime+core
#   parse           0.368s   1588.3MB   405 decls
#   ...
set -u
N=${1:-3}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/medaka"
SINGLE_DRIVER="$ROOT/compiler/entries/profile_main.mdk"
MODULES_DRIVER="$ROOT/compiler/entries/profile_modules_main.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

[ -x "$MAIN" ] || { echo "build first: make medaka (missing $MAIN)" >&2; exit 2; }
[ -f "$SINGLE_DRIVER" ] || { echo "missing $SINGLE_DRIVER" >&2; exit 2; }
[ -f "$MODULES_DRIVER" ] || { echo "missing $MODULES_DRIVER" >&2; exit 2; }

# Parse min-of-N [perf] output from tmpfile and print a table.
# Handles both 3-field format (label, time, ops) and 4-field format (label, time, alloc, ops).
# The total line may have no ops field.
print_min_table() {
  tmpfile="$1"
  awk '
    /^\[perf\] / {
      n = split($0, parts, "\t")
      label = parts[1]
      sub(/^\[perf\] /, "", label)
      t = parts[2]
      sub(/s$/, "", t)
      if (n >= 4) {
        alloc = parts[3]
        sub(/MB$/, "", alloc)
        ops = parts[4]
      } else if (n == 3) {
        alloc = ""
        ops = parts[3]
      } else {
        alloc = ""
        ops = ""
      }
      if (!(label in min_t) || t + 0 < min_t[label] + 0) {
        min_t[label] = t
        alloc_l[label] = alloc
        ops_l[label] = ops
      }
      if (!(label in seen)) {
        seen[label] = 1
        order[++cnt] = label
      }
    }
    END {
      fmt = "%-16s  %8s  %9s  %s\n"
      printf fmt, "stage", "min", "alloc", "ops"
      printf fmt, "-----", "---", "-----", "---"
      for (i = 1; i <= cnt; i++) {
        l = order[i]
        a = (alloc_l[l] != "") ? alloc_l[l] "MB" : "-"
        printf "%-16s  %7ss  %8s  %s\n", l, min_t[l], a, ops_l[l]
      }
    }
  ' "$tmpfile"
}

profile_single() {
  target="$1"
  echo "=== $target (min-of-$N, single-file) ==="
  tmpfile="$(mktemp)"
  i=1
  while [ "$i" -le "$N" ]; do
    MEDAKA_PERF=1 "$MAIN" run "$SINGLE_DRIVER" "$RUNTIME" "$CORE" "$target" 2>>"$tmpfile" >/dev/null
    i=$((i + 1))
  done
  print_min_table "$tmpfile"
  rm -f "$tmpfile"
  printf '\n'
}

profile_modules() {
  entry="$1"
  root="$2"
  echo "=== $entry (min-of-$N, multi-module) ==="
  tmpfile="$(mktemp)"
  i=1
  while [ "$i" -le "$N" ]; do
    MEDAKA_PERF=1 "$MAIN" run "$MODULES_DRIVER" "$RUNTIME" "$CORE" "$entry" "$root" 2>>"$tmpfile" >/dev/null
    i=$((i + 1))
  done
  print_min_table "$tmpfile"
  rm -f "$tmpfile"
  printf '\n'
}

profile_single "$ROOT/compiler/frontend/lexer.mdk"
profile_single "$ROOT/compiler/frontend/parser.mdk"
profile_modules "$ROOT/compiler/entries/all_modules_entry.mdk" "$ROOT/compiler"
