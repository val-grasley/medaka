# Medaka Linux build/test container.
#
# Purpose: run `make medaka` + the gate suite entirely INSIDE a Linux VM
# container so the write storm (67 clang oracle builds + thousands of temp
# files) never touches the host filesystem — keeping the host DLP/endpoint
# scanner near its idle floor. See docker/README.md and scripts/docker-dev.sh.
#
# arm64-native (no qemu): the digest below is debian stable-slim (Debian 13
# "trixie") linux/arm64, pinned for reproducibility. Rebuild on Apple Silicon
# with `--platform` unset so it builds natively.
FROM debian@sha256:ee12ffb55625b99d62837a72f037d9b2f18fd0c787a89c2b9a4f09666c48776c

# Toolchain the cold seed-bootstrap + warm rebuild + gate suite need:
#   clang            — LLVM text IR -> native aarch64-linux binary
#   libgc-dev        — Boehm GC (<gc.h>, -lgc, and a bdw-gc.pc for pkg-config)
#   make/bash/perl   — build driver + test timeout shims + scripts
#   coreutils/gzip   — seed expansion (gunzip) + od/head/cmp used by bootstrap
#   git              — some scripts probe repo root; harmless if absent
#   pkg-config       — detectGC's preferred libgc probe
#   python3          — LSP/analyze_project gate harnesses (JSON-RPC framing)
#   rsync            — docker-dev.sh copies source into the internal volume
#   ca-certificates  — general hygiene
RUN apt-get update && apt-get install -y --no-install-recommends \
        clang \
        libgc-dev \
        libc6-dev \
        make \
        bash \
        perl \
        coreutils \
        gzip \
        git \
        pkg-config \
        python3 \
        rsync \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The build/test writes ALL land under here — backed by a named Docker volume
# at runtime (docker-dev.sh), never a host bind mount.
WORKDIR /work/repo

CMD ["/bin/bash"]
