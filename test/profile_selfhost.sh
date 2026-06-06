#!/bin/sh
# Per-stage performance profiling for the self-hosted pipeline (single-file path).
# Runs selfhost/profile_main.mdk over representative target files, collecting N
# timed runs and reporting per-stage minimums as a table.
#
# Usage:  sh test/profile_selfhost.sh [N]
#
# N defaults to 3 (min-of-3 is the standard baseline per PERF-NOTES.md).
# Results go to stdout; progress/debug goes to stderr.
#
# Files profiled:
#   selfhost/lexer.mdk     — self-contained (no imports); all stages accurate
#   selfhost/parser.mdk    — large file with imports; parse+desugar accurate
#
# Output format (one table per file):
#   === <file> (min-of-N) ===
#   stage             min        ops
#   -----             ---        ---
#   parse-prelude   0.228s   runtime+core
#   parse           0.089s   958 decls
#   ...
#
# Complements perf_main.mdk (which times the multi-module loader path, bundling
# mark+typecheck into a single 'elaborate' phase).
set -u
N=${1:-3}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
DRIVER="$ROOT/selfhost/profile_main.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)" >&2; exit 2; }
[ -f "$DRIVER" ] || { echo "missing $DRIVER" >&2; exit 2; }

profile_file() {
  target="$1"
  echo "=== $target (min-of-$N) ==="
  tmpfile="$(mktemp)"
  i=1
  while [ "$i" -le "$N" ]; do
    MEDAKA_PERF=1 "$MAIN" run "$DRIVER" "$RUNTIME" "$CORE" "$target" 2>>"$tmpfile" >/dev/null
    i=$((i + 1))
  done
  # Compute per-stage minimums across all N runs.
  # [perf] line format: "[perf] STAGE\tTIMEs\tops"
  # (emitTotal omits the ops field — handled by the n>=3 guard below)
  awk '
    /^\[perf\] / {
      n = split($0, parts, "\t")
      label = parts[1]
      sub(/^\[perf\] /, "", label)
      t = parts[2]
      sub(/s$/, "", t)
      ops = (n >= 3) ? parts[3] : ""
      if (!(label in min_t) || t + 0 < min_t[label] + 0) {
        min_t[label] = t
        ops_l[label] = ops
      }
      if (!(label in seen)) {
        seen[label] = 1
        order[++cnt] = label
      }
    }
    END {
      fmt = "%-16s  %8s  %s\n"
      printf fmt, "stage", "min", "ops"
      printf fmt, "-----", "---", "---"
      for (i = 1; i <= cnt; i++) {
        l = order[i]
        printf "%-16s  %7ss  %s\n", l, min_t[l], ops_l[l]
      }
    }
  ' "$tmpfile"
  rm -f "$tmpfile"
  printf '\n'
}

profile_file "$ROOT/selfhost/lexer.mdk"
profile_file "$ROOT/selfhost/parser.mdk"
