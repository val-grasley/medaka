#!/bin/sh
# bench.sh — native-backend performance harness for Medaka.
#
# Times the standard workloads on the CURRENT sources/binary and prints a table.
# Companion to selfhost/PERF-SCOPE.md (plan) and selfhost/PERF-RESULTS.md (log).
#
# Workloads:
#   fib 38      test/bench_fixtures/fib.mdk     — pure compute, NO heap alloc.
#   listsum     test/bench_fixtures/listsum.mdk — cons churn / GC pressure.
#   selfcompile native emitter emitting its OWN module graph (~10 MB IR) — the
#               heaviest representative workload, the OCaml-retirement perf bar.
#
# It builds each fixture via `medaka build` (so it picks up whatever clang flags
# the build driver currently uses) and times the native binary min-of-N.
# `selfcompile` additionally builds the emitter once, then times it.
#
# Usage:
#   sh test/bench.sh            # N=3, all workloads
#   sh test/bench.sh -n 5       # min-of-5
#   sh test/bench.sh --quick    # skip selfcompile + interpreter (fast micros only)
#   sh test/bench.sh --interp   # also time the OCaml interpreter self-compile (slow)
#
# Quiet-machine discipline (see PERF-SCOPE §2b): run single-threaded, close other
# apps, warm the file cache (the harness warms once before timing).
#
# Exit: 0 ok; 2 if prerequisites are missing (binary not built, no clang/libgc).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Prefer the native `medaka` (the OCaml `medaka build` path is dead — its
# interpreter can no longer parse the selfhost emitter source). Builds shell out
# to an emitter, so point MEDAKA_EMITTER at the native emitter for OCaml-free builds.
if [ -x "$ROOT/medaka" ]; then
  MAIN="$ROOT/medaka"
  [ -x "$ROOT/medaka_emitter" ] && export MEDAKA_EMITTER="$ROOT/medaka_emitter"
else
  MAIN="$ROOT/_build/default/bin/main.exe"
fi
EMIT_DRIVER="selfhost/entries/llvm_emit_modules_main.mdk"
RUNTIME="stdlib/runtime.mdk"
CORE="stdlib/core.mdk"

N=3
DO_SELFCOMPILE=1
DO_INTERP=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n) N="$2"; shift 2 ;;
    --quick) DO_SELFCOMPILE=0; shift ;;
    --interp) DO_INTERP=1; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "no clang on PATH — skipping"; exit 2; }

cd "$ROOT" || exit 2

# macOS /usr/bin/time -l prints "real" and "maximum resident set size"; GNU time
# differs. Detect once.
TIMEL="/usr/bin/time -l"
$TIMEL true >/dev/null 2>&1 || { echo "/usr/bin/time -l unavailable (macOS only) — skipping"; exit 2; }

# run CMD N times, print "  min=<s>s  rss=<MB>MB" using the min real over runs.
time_min() {
  _best=""; _rss=""
  i=0
  while [ "$i" -lt "$N" ]; do
    $TIMEL "$@" >/dev/null 2>/tmp/_bench_t.$$
    _r="$(awk '/real/{print $1}' /tmp/_bench_t.$$)"
    _m="$(awk '/maximum resident/{print $1}' /tmp/_bench_t.$$)"
    if [ -z "$_best" ] || awk "BEGIN{exit !($_r < $_best)}"; then _best="$_r"; _rss="$_m"; fi
    i=$((i + 1))
  done
  rm -f /tmp/_bench_t.$$
  printf 'min=%ss  rss=%dMB' "$_best" "$((_rss / 1048576))"
}

echo "== Medaka native-backend benchmark =="
echo "host: $(uname -m)  clang: $(clang --version | head -1 | sed 's/ (.*//')"
echo "N=$N (min-of-$N), single-threaded recommended"
echo

# ── micro: fib (no alloc) ────────────────────────────────────────────────────
echo "building fib..."; "$MAIN" build test/bench_fixtures/fib.mdk -o /tmp/_bench_fib >/dev/null 2>&1 \
  || { echo "fib build FAILED"; exit 2; }
"/tmp/_bench_fib" >/dev/null 2>&1 # warm
printf 'fib 38       %s\n' "$(time_min /tmp/_bench_fib)"

# ── micro: listsum (GC pressure) ─────────────────────────────────────────────
echo "building listsum..."; "$MAIN" build test/bench_fixtures/listsum.mdk -o /tmp/_bench_ls >/dev/null 2>&1 \
  || { echo "listsum build FAILED"; exit 2; }
"/tmp/_bench_ls" >/dev/null 2>&1 # warm
printf 'listsum      %s\n' "$(time_min /tmp/_bench_ls)"

# ── runtime micro-suite (float/ADT/list/closure/string) ──────────────────────
# See selfhost/PERF-RUNTIME.md. floatsum/mandel isolate float boxing (Win 1/2:
# fusion + let-unboxing); bintrees = ADT/GC; listops/closures = cons/closure churn.
for b in intsum floatsum floatsum_guard mandel mandel_let bintrees closures strbuild dispatch strlit listlit; do
  src="test/bench_fixtures/$b.mdk"
  [ -f "$src" ] || continue
  if "$MAIN" build "$src" -o "/tmp/_bench_$b" >/dev/null 2>&1; then
    "/tmp/_bench_$b" >/dev/null 2>&1 # warm
    printf '%-12s %s\n' "$b" "$(time_min "/tmp/_bench_$b")"
  else
    printf '%-12s BUILD FAILED\n' "$b"
  fi
done

# ── selfcompile (representative heavy workload) ──────────────────────────────
if [ "$DO_SELFCOMPILE" -eq 1 ]; then
  echo "building native emitter (slow: clang of ~10 MB IR)..."
  "$MAIN" build "$EMIT_DRIVER" -o /tmp/_bench_emitter >/dev/null 2>&1 \
    || { echo "emitter build FAILED"; exit 2; }
  /tmp/_bench_emitter "$RUNTIME" "$CORE" "$EMIT_DRIVER" selfhost stdlib >/dev/null 2>&1 # warm
  printf 'selfcompile  %s\n' \
    "$(time_min /tmp/_bench_emitter "$RUNTIME" "$CORE" "$EMIT_DRIVER" selfhost stdlib)"

  if [ "$DO_INTERP" -eq 1 ]; then
    echo "timing OCaml interpreter self-compile (slow, ~2 min/run)..."
    printf 'selfcompile(interp)  %s\n' \
      "$(time_min "$MAIN" run "$EMIT_DRIVER" "$RUNTIME" "$CORE" "$EMIT_DRIVER" selfhost stdlib)"
  fi
fi

echo
echo "done. log results in selfhost/PERF-RESULTS.md"
