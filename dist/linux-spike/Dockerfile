FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
      clang lld libgc-dev pkg-config gzip make binutils file gdb ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
