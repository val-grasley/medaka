#!/bin/sh
set -u
tar -x -C /src -f /host/repo.tar
cd /src
GC_CFLAGS="$(pkg-config --cflags bdw-gc)"; GC_LIBS="$(pkg-config --libs bdw-gc)"
gunzip -c compiler/seed/emitter.ll.gz > /tmp/seed.ll
echo "=== build -O0 emitter with symbols ==="
clang -O0 -g $GC_CFLAGS /tmp/seed.ll runtime/medaka_rt.c $GC_LIBS -lm -o /tmp/se 2>/dev/null && echo built || { echo BUILD-FAIL; exit 1; }

ulimit -s 8192
ARGS="stdlib/runtime.mdk stdlib/core.mdk compiler/entries/llvm_emit_modules_main.mdk compiler stdlib"
echo "=== run under gdb (8MB stack -> overflow) ==="
gdb -batch -q \
  -ex 'set pagination off' \
  -ex "run $ARGS > /dev/null 2> /dev/null" \
  -ex 'printf "SIGNAL / STOP REASON:\n"' \
  -ex 'info program' \
  -ex 'printf "\n===== INNERMOST 45 FRAMES =====\n"' \
  -ex 'bt 45' \
  -ex 'printf "\n===== DEEPER SAMPLE (frames 900-960, to confirm the cycle repeats) =====\n"' \
  -ex 'bt -60' \
  /tmp/se > /tmp/bt.txt 2>&1

echo "----- raw gdb output (first 80 lines) -----"
head -80 /tmp/bt.txt
echo
echo "===== FUNCTION HISTOGRAM over the whole captured backtrace ====="
grep -oE 'in [A-Za-z_][A-Za-z0-9_]*' /tmp/bt.txt | sed 's/^in //' | sort | uniq -c | sort -rn | head -30
echo "=== DONE ==="
