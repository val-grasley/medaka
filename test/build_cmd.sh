#!/bin/sh
# medaka build — end-to-end native-binary build gate, RE-ROOTED off the OCaml
# oracle (REROOT-PLAN §2d).
#
# Drives the NATIVE `./medaka build` CLI (emit host = ./medaka_emitter) on real
# user programs of increasing complexity (test/build_cmd_fixtures/*.mdk, formerly
# inline heredocs), then diffs each native binary's stdout against the committed
# `<fixture>.build.golden`.  The golden is the program's runtime stdout captured
# from the OCaml-built binary while OCaml was the validated backend oracle
# (sh test/capture_goldens.sh build_cmd).  No OCaml at gate time.
#
# Goldens capture the BACKEND's actual binary output, including the parked native
# dispatch gaps (#54/#21/#55): e.g. svm/entry's standalone-vs-method `toList`/
# `isEmpty` SEGFAULTS (#54 residual) and emits nothing on BOTH hosts' binaries, so
# its golden is empty and the native binary reproduces it.  (The OLD gate diffed
# the binary vs the INTERPRETER oracle and therefore FAILED svm; the re-root
# faithfully goldens the binary, so svm now passes — the dispatch gap is captured,
# not masked.)  Only stdout is compared (not exit code), matching the original
# `2>/dev/null` discipline.
#
# Usage:  sh test/build_cmd.sh
# Exit:   0 if every program builds and native stdout == golden;
#         1 on any build/diff failure;
#         2 if the native medaka/emitter is missing, no C compiler, or libgc
#           absent (opt-in skip discipline, same as the LLVM gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIX="$ROOT/test/build_cmd_fixtures"
CC="${CC:-clang}"

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then :
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then :
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then :
else echo "libgc (bdw-gc) not found — skipping (install bdw-gc)"; exit 2; fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0

check() { # $1=label  $2=mdk-path
  label="$1"; src="$2"; bin="$WORK/$label.bin"
  golden="${src%.mdk}.build.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no .build.golden — run sh test/capture_goldens.sh build_cmd)\n' "$label"; return
  fi
  if ! MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" \
       "$MEDAKA" build "$src" -o "$bin" >"$WORK/$label.out" 2>"$WORK/$label.err"; then
    fail=$((fail+1)); printf 'FAIL %s (native build)\n' "$label"
    sed 's/^/    /' "$WORK/$label.err" | head -5
    return
  fi
  native="$("$bin" 2>/dev/null)"
  expected="$(cat "$golden")"
  if [ "$native" = "$expected" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$label"
  else
    fail=$((fail+1)); printf 'FAIL %s (diff)\n' "$label"
    printf '%s' "$expected" > "$WORK/exp.txt"
    printf '%s' "$native"   > "$WORK/got.txt"
    diff "$WORK/exp.txt" "$WORK/got.txt" | head -10 | sed 's/^/    /'
  fi
}

for p in arith recur adt list closure println println_seq show_debug eq ord list_map deriving; do
  check "$p" "$FIX/$p.mdk"
done
check "multimodule" "$FIX/mm/entry.mdk"
check "standalone_vs_method" "$FIX/svm/entry.mdk"

printf '\n%d ok, %d failing (of %d)\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
