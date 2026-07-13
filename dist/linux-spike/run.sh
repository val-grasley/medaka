#!/bin/sh
# One-command Linux native-build harness (Docker). Drives the D0-D4 distribution
# work on a Linux target from a macOS (or Linux) host — see ../../docs/ops/DISTRIBUTION-DESIGN.md.
#
# Usage:  sh run.sh [spike|experiment|bt]     (default: spike)
#   spike       full pipeline: cold-bootstrap from seed -> medaka CLI -> medaka
#               run/build hello.mdk end-to-end (the D0 viability check).
#   experiment  stack-size threshold sweep (-O0 vs -O2, 8..256MB).
#   bt          gdb backtrace at the 8MB stack overflow (shows the recursion shape).
#
# It snapshots the CURRENT WORKING TREE (uncommitted edits included) into repo.tar,
# so you can edit e.g. compiler/frontend/lexer.mdk (Track 2 TMC) or the build
# scripts (Track 1 stack) and re-run immediately. Build artifacts are excluded.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)"
which="${1:-spike}"

echo "==> snapshot working tree -> repo.tar"
tar --exclude='./.git' --exclude='*.o' --exclude='./medaka' --exclude='./medaka_emitter' \
    --exclude='./seed_emitter' --exclude='./playground/dist' --exclude='./playground/vendor' \
    --exclude='./dist/linux-spike/repo.tar' \
    -cf "$here/repo.tar" -C "$root" .

echo "==> docker build medaka-linux-spike"
docker build -t medaka-linux-spike "$here"

echo "==> docker run $which.sh  (512MB stack hard-limit; scripts set soft limits themselves)"
docker run --rm --ulimit stack=536870912:536870912 -v "$here":/host medaka-linux-spike sh "/host/$which.sh"
