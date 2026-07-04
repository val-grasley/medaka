#!/bin/sh
# Characterize the Linux emitter stack overflow:
#  (A) frame-size lever: does building the emitter at -O2 (smaller frames) clear
#      8MB, vs the -O0 the spike used?
#  (B) threshold: how deep does the -O0 emitter actually need? (8/16/32/64/128 MB)
# The overflowing work = seed_emitter re-emitting the whole compiler graph.
set -u
tar -x -C /src -f /host/repo.tar
sed -i 's/-Wl,-stack_size,"\$STACK_SIZE" //g' /src/test/bootstrap_from_seed.sh
cd /src
RT=runtime/medaka_rt.c; RUNTIME=stdlib/runtime.mdk; CORE=stdlib/core.mdk
DRIVER=compiler/entries/llvm_emit_modules_main.mdk; SELFHOST=compiler; STDLIB=stdlib
GC_CFLAGS="$(pkg-config --cflags bdw-gc)"; GC_LIBS="$(pkg-config --libs bdw-gc)"
gunzip -c compiler/seed/emitter.ll.gz > /tmp/seed.ll

echo "=== build seed_emitter at -O0 and -O2 ==="
clang -O0 $GC_CFLAGS /tmp/seed.ll "$RT" $GC_LIBS -lm -o /tmp/se_O0 2>/dev/null && echo "O0 built" || echo "O0 build FAIL"
clang -O2 $GC_CFLAGS /tmp/seed.ll "$RT" $GC_LIBS -lm -o /tmp/se_O2 2>/dev/null && echo "O2 built" || echo "O2 build FAIL"

emit() {  # emit <binary> <stack-KB> <label>
  ( ulimit -s "$2" 2>/dev/null
    if "$1" "$RUNTIME" "$CORE" "$DRIVER" "$SELFHOST" "$STDLIB" >/tmp/out.ll 2>/tmp/e.err; then
      echo "  [$3] stack=$(( $2 / 1024 ))MB  -> PASS ($(wc -l </tmp/out.ll) lines IR)"
    else
      echo "  [$3] stack=$(( $2 / 1024 ))MB  -> FAIL: $(tr -d '\0' </tmp/e.err | tail -1)"
    fi )
}

echo "=== (A) frame-size lever: -O0 vs -O2 at 8MB ==="
emit /tmp/se_O0 8192  "O0"
emit /tmp/se_O2 8192  "O2"

echo "=== (B) -O0 threshold sweep ==="
for kb in 8192 16384 32768 65536 131072 262144; do emit /tmp/se_O0 "$kb" "O0"; done

echo "=== (C) -O2 threshold sweep (if 8MB failed) ==="
for kb in 8192 16384 32768 65536; do emit /tmp/se_O2 "$kb" "O2"; done
echo "=== DONE ==="
