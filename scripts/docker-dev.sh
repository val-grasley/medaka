#!/usr/bin/env bash
# docker-dev.sh — run Medaka's build + gate suite entirely INSIDE a Linux VM
# container so the build's write storm (67 clang oracle builds + thousands of
# temp files) never lands on the host filesystem, keeping a host DLP/endpoint
# scanner (Cyberhaven) near its idle floor.
#
# CRITICAL INVARIANT: every build/test WRITE lands on the container's INTERNAL
# filesystem — a persistent NAMED Docker volume ("$VOLUME" -> /work). Source is
# copied IN from a READ-ONLY bind mount via rsync; NO writable host bind mount is
# ever used (a `-v host:container` mount that receives writes routes them back to
# the host FS and defeats the whole purpose). Artifacts (./medaka, medaka_emitter,
# test/bin oracles) persist in the volume across runs, so incremental rebuilds and
# oracle reuse work.
#
# Subcommands:
#   build   sync source -> volume, then `make medaka` (cold-bootstraps from seed
#           the first time; warm 2-stage rebuild after)
#   test    sync source -> volume, build oracles if missing, run the gate suite
#           (JOBS/INNER_JOBS capped conservatively — the host is shared)
#   shell   sync source -> volume, drop into an interactive bash in the container
#   sync    just rsync source -> volume (no build)
#   gates   run the gate suite WITHOUT re-syncing/re-building oracles (fast re-run)
#
# Path-agnostic: the repo root is derived from `git rev-parse --show-toplevel`
# (falling back to this script's location), so it works from any checkout.
set -euo pipefail

# ── Repo root (path-agnostic — no hardcoded paths) ───────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# NOTE the two separate assignments: `$(git … || cd … && pwd)` would mis-parse as
# `(git || cd) && pwd`, appending pwd's output when git SUCCEEDS and yielding a
# two-line REPO_ROOT — which becomes a garbage `/src` mount and makes rsync
# --delete run against an empty source (wiping the volume). Keep them separate.
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE="${MEDAKA_DOCKER_IMAGE:-medaka-dev:latest}"
VOLUME="${MEDAKA_DOCKER_VOLUME:-medaka-work}"
DOCKERFILE="$REPO_ROOT/docker/Dockerfile"
# Conservative caps: the host is shared, so don't saturate it.
JOBS="${JOBS:-4}"
INNER_JOBS="${INNER_JOBS:-2}"

# Container-internal paths (all under the named volume).
C_WORK="/work"
C_REPO="/work/repo"

log() { printf '\033[1;36m[docker-dev]\033[0m %s\n' "$*" >&2; }

ensure_image() {
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "building image $IMAGE (arm64-native) ..."
    docker build -t "$IMAGE" -f "$DOCKERFILE" "$REPO_ROOT/docker"
  fi
}

ensure_volume() {
  docker volume inspect "$VOLUME" >/dev/null 2>&1 || {
    log "creating named volume $VOLUME (container-internal FS)"
    docker volume create "$VOLUME" >/dev/null
  }
}

# rsync the repo source into the volume from a READ-ONLY mount. Reads of the host
# FS don't trigger the write scanner; the write side is the volume (internal).
# .git and build artifacts are excluded — artifacts already live in the volume.
sync_source() {
  ensure_image; ensure_volume
  # Sanity: the repo root must look like the Medaka checkout. Guards against a
  # bad REPO_ROOT producing an empty/garbage /src mount that rsync --delete would
  # then use to wipe the volume.
  [ -f "$REPO_ROOT/AGENTS.md" ] || { echo "refusing to sync: $REPO_ROOT is not a Medaka checkout (no AGENTS.md)" >&2; exit 1; }
  log "syncing source -> volume $VOLUME:/work/repo (read-only source mount) ..."
  # `--delete` only after confirming /src actually mounted the source (sentinel
  # file present) — belt-and-suspenders against an empty-source wipe.
  docker run --rm \
    -v "$REPO_ROOT":/src:ro \
    -v "$VOLUME":"$C_WORK" \
    "$IMAGE" \
    bash -c '[ -f /src/AGENTS.md ] || { echo "ABORT: /src did not mount the source tree" >&2; exit 1; }; exec "$@"' _ \
    rsync -a --delete \
      --exclude='.git' \
      --exclude='/medaka' \
      --exclude='/medaka_emitter' \
      --exclude='*.o' \
      --exclude='playground/dist' \
      --exclude='playground/e2e/node_modules' \
      --exclude='test/bin' \
      /src/ "$C_REPO/"
}

# Run a command in the container with ONLY the named volume mounted (no host
# bind mount → all writes stay internal). MEDAKA_EMITTER points at the persisted
# native emitter so `medaka build`/oracle builds are OCaml-free.
run_in_container() {
  ensure_image; ensure_volume
  docker run --rm -it \
    -v "$VOLUME":"$C_WORK" \
    -e MEDAKA_EMITTER="$C_REPO/medaka_emitter" \
    -e JOBS="$JOBS" -e INNER_JOBS="$INNER_JOBS" \
    -w "$C_REPO" \
    "$IMAGE" "$@"
}
# Non-interactive variant (no -it) for scripted/CI use.
run_in_container_noninteractive() {
  ensure_image; ensure_volume
  docker run --rm \
    -v "$VOLUME":"$C_WORK" \
    -e MEDAKA_EMITTER="$C_REPO/medaka_emitter" \
    -e JOBS="$JOBS" -e INNER_JOBS="$INNER_JOBS" \
    -w "$C_REPO" \
    "$IMAGE" "$@"
}

cmd_build() {
  sync_source
  log "make medaka (cold-bootstraps from seed on first run) ..."
  run_in_container_noninteractive bash -c 'make medaka'
}

cmd_gates() {
  log "running gate suite (JOBS=$JOBS INNER_JOBS=$INNER_JOBS) ..."
  run_in_container_noninteractive bash -c '
    set -e
    if [ ! -x ./medaka ]; then echo "no ./medaka in volume — run: docker-dev.sh build" >&2; exit 1; fi
    if [ -z "$(ls -A test/bin 2>/dev/null)" ]; then
      echo "[docker-dev] building oracles (first run) ..." >&2
      FORCE=1 JOBS="$JOBS" bash test/build_oracles.sh
    fi
    INNER_JOBS="$INNER_JOBS" JOBS="$JOBS" sh test/run_gates.sh
  '
}

cmd_test() {
  sync_source
  run_in_container_noninteractive bash -c 'make medaka'
  cmd_gates
}

cmd_shell() {
  sync_source
  log "interactive shell in container (writes land in volume $VOLUME) ..."
  run_in_container bash
}

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  echo
  echo "Usage: $0 {build|test|gates|shell|sync}"
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    build) cmd_build "$@" ;;
    test)  cmd_test "$@" ;;
    gates) cmd_gates "$@" ;;
    shell) cmd_shell "$@" ;;
    sync)  sync_source ;;
    ""|-h|--help|help) usage ;;
    *) echo "unknown subcommand: $sub" >&2; usage; exit 2 ;;
  esac
}

main "$@"
