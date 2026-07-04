#!/bin/sh
# D0 Linux native-build spike — driven inside an Ubuntu container.
# Question: does the deeply-recursive self-hosted emitter build + run on Linux,
# where the macOS 512MB -Wl,-stack_size link flag is unavailable (GNU ld rejects
# it) and the main-thread stack is governed by RLIMIT_STACK instead?
set -u

echo "############ ENV ############"
clang --version | head -1
ld --version | head -1
pkg-config --exists bdw-gc && echo "bdw-gc: $(pkg-config --modversion bdw-gc)" || echo "bdw-gc: MISSING"
uname -a
echo "ulimit -s (soft): $(ulimit -s)"
echo "ulimit -s -H (hard): $(ulimit -s -H)"

echo "############ UNPACK ############"
tar -x -C /src -f /host/repo.tar
echo "unpacked $(find /src -name '*.mdk' | wc -l) .mdk files; seed: $(ls -la /src/compiler/seed/emitter.ll.gz | awk '{print $5}') bytes"

echo "############ PATCH: drop Mach-O -Wl,-stack_size (GNU ld rejects it) ############"
# (1)+(2) build scripts, (3) build_cmd.mdk for the `medaka build` user-link path.
sed -i 's/-Wl,-stack_size,"\$STACK_SIZE" //g' /src/test/bootstrap_from_seed.sh /src/test/build_native_medaka.sh
sed -i 's/"-Wl,-stack_size,0x20000000", //' /src/compiler/driver/build_cmd.mdk
echo "residual stack_size refs (expect 0):"
grep -rc 'stack_size' /src/test/bootstrap_from_seed.sh /src/test/build_native_medaka.sh /src/compiler/driver/build_cmd.mdk

echo "############ PATCH: add -lm (Linux needs explicit libm; macOS bundles it in libSystem) ############"
sed -i 's/\$GC_LIBS -o/$GC_LIBS -lm -o/g' /src/test/bootstrap_from_seed.sh /src/test/build_native_medaka.sh
sed -i 's/\["-o", outPath\]/["-lm", "-o", outPath]/' /src/compiler/driver/build_cmd.mdk
echo "libm refs added (expect >0):"
grep -c 'lm' /src/test/bootstrap_from_seed.sh; grep -c '"-lm"' /src/compiler/driver/build_cmd.mdk

cd /src

echo "############ STEP 1: cold bootstrap emitter from seed ############"
echo "(step 2 inside = seed_emitter recursively re-emits the whole compiler graph = THE stack test)"
t0=$(date +%s)
SEED_TOLERANT=1 sh test/bootstrap_from_seed.sh
rc=$?; echo ">>> bootstrap rc=$rc  ($(( $(date +%s) - t0 ))s)"
if [ ! -x /src/medaka_emitter ]; then echo ">>> FATAL: no medaka_emitter produced"; exit 1; fi
file /src/medaka_emitter

echo "############ STEP 2: build the medaka CLI ############"
t0=$(date +%s)
sh test/build_native_medaka.sh
rc=$?; echo ">>> build_native rc=$rc  ($(( $(date +%s) - t0 ))s)"
if [ ! -x /src/medaka ]; then echo ">>> FATAL: no medaka CLI produced"; exit 1; fi
file /src/medaka

echo "############ STEP 3: end-to-end run + build ############"
export MEDAKA_ROOT=/src
export MEDAKA_EMITTER=/src/medaka_emitter
printf 'main = println (1 + 2)\n' > /src/hello.mdk

echo "--- medaka run hello.mdk (tree-walk interpreter) ---"
/src/medaka run /src/hello.mdk; echo ">>> run rc=$?"

echo "--- medaka build hello.mdk -> native ELF (the real target) ---"
/src/medaka build /src/hello.mdk -o /src/hello; echo ">>> build rc=$?"
file /src/hello 2>/dev/null || echo "no /src/hello produced"

echo "--- execute the built native binary ---"
/src/hello; echo ">>> exec rc=$?  (expect output '3')"

echo "############ DONE ############"
