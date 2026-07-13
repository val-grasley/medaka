#!/usr/bin/env bash
# provision.sh — stand up a Medaka build box on a fresh Debian/Ubuntu server.
#
# Self-contained: copy JUST this file to the box (scp/paste) and run it. It
# installs the toolchain, clones the (private) repo over your forwarded SSH
# agent, cold-bootstraps the native compiler from the checked-in seed, installs
# the pre-commit hook, runs the gate suite, and prints a PASS/FAIL banner.
#
# Primary target: Netcup RS G12 root server (install Debian 12 via the SCP
# control panel, then `ssh -A root@<ip>` and run this). Works on any
# Debian/Ubuntu box (Hetzner CX, a local Ryzen box, etc.) unchanged.
#
#   scp ops/provision.sh root@<ip>:                 # from your laptop
#   ssh -A root@<ip>                                # -A forwards your agent (private clone)
#   ./provision.sh                                  # ~a few min: deps + build + gates
#
# Env knobs:
#   MEDAKA_REPO   git URL         (default git@github.com:MedakaLang/medaka.git)
#   MEDAKA_DIR    checkout path   (default $HOME/medaka)
#   GC_INITIAL_HEAP_SIZE          (default 2g — defers Boehm GC on the serial emit)
set -uo pipefail

REPO="${MEDAKA_REPO:-git@github.com:MedakaLang/medaka.git}"
WORKDIR="${MEDAKA_DIR:-$HOME/medaka}"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
export DEBIAN_FRONTEND=noninteractive
log() { printf '\n== %s ==\n' "$*"; }

# 1. Toolchain — the docker/Dockerfile set + Node 24 (wasm/sqlite/playground gates).
#    `sqlite3` is the differential ORACLE for every sqlite/test/*_oracle.sh; without
#    it those 18 gates die on the first CREATE TABLE. `wasm-tools` is what every wasm
#    gate shells out to (test/build_wasm_cmd.sh); without it they all report "skipping"
#    and exit 0 — a silent no-op that reads as green. Both were missing on the first
#    provisioned box.
#    `jq` is the same lesson a third time, and it cost a whole session's CI monitoring
#    (2026-07-14). It is NOT used by any gate — the gates stay POSIX sh + awk for the
#    dual-platform invariant — but every orchestrator and agent reaches for it when
#    scripting against `gh`, and its absence fails the way the other two did: a shell
#    pipeline into a missing `jq` yields an EMPTY STRING, not an error, so the script
#    sails on and reports nothing while appearing to run. A background PR/CI monitor
#    built that way watched precisely nothing, all night, and looked healthy doing it.
#    (`gh` has a built-in `--jq`, which is why the same expression works by hand and
#    dies inside a script — an especially nasty way to be wrong.)
log "installing toolchain (clang, libgc, node 24, sqlite3, jq, ...)"
$SUDO apt-get update -qq
$SUDO apt-get install -y --no-install-recommends \
  clang libgc-dev libc6-dev make bash perl coreutils gzip git \
  pkg-config python3 rsync ca-certificates curl sqlite3 jq
NODE_MAJOR="$(node -v 2>/dev/null | sed 's/v\([0-9]*\).*/\1/')"
if [ -z "$NODE_MAJOR" ] || [ "$NODE_MAJOR" -lt 24 ]; then
  # NodeSource setup, piped safe for both root ($SUDO empty) and sudo users —
  # fetch to a file first so we never pipe into `$SUDO -E bash` (breaks as root).
  curl -fsSL https://deb.nodesource.com/setup_24.x -o /tmp/nodesource_setup.sh
  $SUDO bash /tmp/nodesource_setup.sh
  $SUDO apt-get install -y nodejs
fi

# wasm-tools — no apt package and no Rust toolchain here, so take the upstream
# prebuilt release binary.
if ! command -v wasm-tools >/dev/null 2>&1; then
  WT_VER=1.219.1
  WT_TGZ="/tmp/wasm-tools-${WT_VER}.tar.gz"
  curl -fsSL -o "$WT_TGZ" \
    "https://github.com/bytecodealliance/wasm-tools/releases/download/v${WT_VER}/wasm-tools-${WT_VER}-x86_64-linux.tar.gz"
  tar xzf "$WT_TGZ" -C /tmp
  $SUDO install -m755 "/tmp/wasm-tools-${WT_VER}-x86_64-linux/wasm-tools" /usr/local/bin/wasm-tools
fi

# 2. Clone — private repo, so this needs your forwarded ssh-agent (ssh -A).
log "cloning $REPO -> $WORKDIR"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keyscan -t ed25519,rsa github.com >> ~/.ssh/known_hosts 2>/dev/null || true
if [ ! -d "$WORKDIR/.git" ]; then
  git clone "$REPO" "$WORKDIR" || {
    echo "CLONE: FAIL — did you 'ssh -A' so your GitHub key forwards? (or add a deploy key)"; exit 1; }
fi
cd "$WORKDIR"

# 3. Pre-commit hook (fmt + lint ratchet).
log "installing pre-commit hook"
cp .githooks/pre-commit "$(git rev-parse --git-common-dir)/hooks/pre-commit" \
  && chmod +x "$(git rev-parse --git-common-dir)/hooks/pre-commit"

# 4. Cold-bootstrap the native compiler from compiler/seed/emitter.ll.gz.
#    A large initial heap defers Boehm collections ~30% on the SERIAL emit, but
#    must NOT leak into the PARALLEL oracle build (step 6), where big heaps cause
#    ~10x RSS pressure and OOM kills (compiler/PERF-RESULTS.md). So scope it to
#    THIS command with `env`, never `export`.
log "cold-bootstrap: make medaka"
if ! time env GC_INITIAL_HEAP_SIZE="${GC_INITIAL_HEAP_SIZE:-2g}" make medaka; then
  echo; echo "RESULT: BUILD FAIL"; exit 1
fi

# 5. Smoke test the fresh binary actually runs.
log "smoke test"
printf 'main = println "medaka-ok"\n' > /tmp/smoke.mdk
OUT="$(./medaka run /tmp/smoke.mdk 2>&1)"; echo "  -> $OUT"
[ "$OUT" = "medaka-ok" ] || { echo "RESULT: SMOKE FAIL"; exit 1; }

# 6. Gate suite. Build the oracle probe binaries FIRST — without them most
#    diff_compiler_* gates exit 2 (SKIP), yielding a hollow "pass".
log "building oracles (FORCE=1 test/build_oracles.sh)"
FORCE=1 sh test/build_oracles.sh || echo "  (build_oracles reported errors; gates below will SKIP)"
log "gate suite: sh test/run_gates.sh"
if sh test/run_gates.sh; then GATES=PASS; else GATES=FAIL; fi

printf '\n============================================\n'
printf ' BUILD: PASS   SMOKE: PASS   GATES: %s\n' "$GATES"
printf ' arch: %s   -> x86/arm both bootstrap from the same seed\n' "$(uname -m)"
printf '============================================\n'
[ "$GATES" = PASS ]
