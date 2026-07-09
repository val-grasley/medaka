# Dockerized Medaka build + gate suite

Run Medaka's `make medaka` and the differential gate suite **entirely inside a
Linux VM container**, so the build's write storm (67 clang oracle builds +
thousands of temp files) never touches the host filesystem. On a macOS host
running a DLP/endpoint content scanner (Cyberhaven), the native gate suite drives
the scanner to ~1.57 CPU-cores; running it in-container adds only ~0.09 cores.

Measured (back-to-back differential, integrating summed Cyberhaven %cpu at 1 Hz,
since the scanner is many short-lived PIDs and self-spikes independently):
a 60 s IDLE window (nothing running) = 1.46 cores of Cyberhaven; a 60 s window
looping the in-container gate suite = 1.55 cores. **Delta = 0.09 cores** — the
container gate suite's true contribution. (In a genuinely quiescent trough, a
single full in-container gate run measured 1.5 cputime-sec over 66 s wall =
0.02 cores.) Versus 1.57 cores for the native host gate run.

## Why this keeps the host quiet

The critical invariant: **every build/test WRITE lands on a persistent named
Docker volume (`medaka-work`, mounted at `/work`) — never a host bind mount.**
Source is copied IN from a **read-only** bind mount via `rsync` (reads don't
trip the write scanner); all outputs (`./medaka`, `medaka_emitter`, the 53
`test/bin` oracles, every temp `.ll`/binary) stay inside the volume, which lives
in the Docker VM's disk. A writable `-v host:container` mount would route writes
back to the host FS and defeat the entire purpose, so the wrapper never uses one.

Artifacts persist in the volume across runs, so incremental rebuilds and oracle
reuse work.

## Usage

```sh
scripts/docker-dev.sh build    # sync source -> volume, then `make medaka`
                               #   (cold-bootstraps from compiler/seed on 1st run)
scripts/docker-dev.sh test     # build + build oracles (if missing) + run gates
scripts/docker-dev.sh gates    # just run the gate suite (fast re-run; no re-sync)
scripts/docker-dev.sh shell    # interactive shell in the container
scripts/docker-dev.sh sync     # only rsync source -> volume
```

The wrapper derives the repo root from `git rev-parse --show-toplevel`, so it
works from any checkout — no hardcoded paths.

Tunables (env): `JOBS` (default 4), `INNER_JOBS` (default 2) cap in-container
parallelism conservatively since the host is shared; `MEDAKA_DOCKER_IMAGE`,
`MEDAKA_DOCKER_VOLUME` override the image/volume names.

## The image

`docker/Dockerfile` is Debian (stable-slim = Debian 13 "trixie", pinned by
digest), built
**arm64-native** on Apple Silicon (no qemu). Toolchain: `clang`, `libgc-dev`
(Boehm GC), `make`/`bash`/`perl`/`coreutils`/`gzip`, `pkg-config`, `python3`
(LSP/analyze gate harnesses), `rsync`, `git`.

Build it explicitly with `docker build -t medaka-dev:latest -f docker/Dockerfile
docker` (the wrapper also builds it on first use).

## Gate-suite status inside the container

`sh test/run_gates.sh` → **75 passed, 1 failed, 1 skipped**.

- The 1 failure (`diff_compiler_run_check_agreement`) is a **pre-existing RED on
  `main`** (the gate's own output says "RED expected on current main until the
  run==check fix lands") — not Linux-specific.
- The 1 skip (`diff_compiler_lint_multi`) is opt-in.

Two Linux-portability fixes were needed (both darwin-safe):
- `test/diff_compiler_llvm*.sh` link the runtime without `-lm`; glibc needs it
  for the runtime's math functions (macOS folds libm into libSystem). Added
  `-lm` to the three llvm gate link lines.
- Added `python3` to the image for the LSP/analyze_project gate harnesses.

The compiler/runtime source needed **no** changes — `runtime/medaka_rt.c`
already guards its macOS-only bits (`readlink /proc/self/exe` on Linux) and the
emitted LLVM IR is target-neutral.

## Deferred

- **wasm/sqlite gates** — need `node` ≥24 (not installed here); the wasm gates
  are outside this container workflow's scope.
