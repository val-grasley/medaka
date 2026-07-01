#!/usr/bin/env bash
# diff_sqlite.sh — the shared WasmGC-vs-native SQLite tandem oracle (stage C).
#
# For every in-memory sqlite probe in the corpus below, build it for BOTH targets
# from the ONE source and diff stdout:
#   * native  — `./medaka build --allow-internal <probe>` → run the binary
#   * wasm    — `./medaka build --allow-internal --target wasm <probe>` (WasmGC
#               WAT → wasm-tools parse/validate → .wasm) → run under Node >= 22
#
# Because the sqlite lib is bytes-first and cleanly seamed, an in-memory probe
# (inline `Array Int` → buildDatabase → fromBytes → scanTableRows → mutate →
# re-read) needs NO file I/O and runs identically on both backends.  This is the
# tandem-development enabler: a new sqlite feature ships with an in-memory fixture
# added to CORPUS below and it is automatically a wasm test.
#
# Peer of test/wasm/diff_wasm.sh + sqlite/test/*_oracle.sh.  Reports N/M passing;
# non-zero exit on any mismatch.  Opt-in skip (exit 2) when the toolchain
# (wasm-tools / Node>=22 / clang) is unavailable.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
WASM_EMITTER="$ROOT/test/bin/wasm_emit_modules_main"
RUNJS="$ROOT/test/wasm/run.js"
CC="${CC:-clang}"

# The in-memory sqlite probe corpus (multi-module — imports lib.*).  Add a probe
# here and it runs on BOTH backends automatically.
CORPUS=(
  "$ROOT/sqlite/inmem_crud_probe.mdk"
  "$ROOT/sqlite/inmem_aggregate_probe.mdk"
  "$ROOT/sqlite/inmem_orderby_probe.mdk"
  "$ROOT/sqlite/inmem_join_probe.mdk"
  "$ROOT/sqlite/inmem_leftjoin_probe.mdk"
  "$ROOT/sqlite/inmem_distinct_probe.mdk"
)

# The FILE-backed probe corpus (stage D) — probes that exercise the host-I/O externs
# `writeFileBytes` / `readFileBytes` (WRITE a real .sqlite, READ it back, delete/update).
# Each takes ONE path arg; native gets it from argv, wasm from MDK_ARGS (run.js).  Native
# and wasm write to DISTINCT temp paths (no clobber); the printed output is
# path-independent, so stdout is diffed byte-for-byte just like the in-memory arm.
FILE_CORPUS=(
  "$ROOT/sqlite/file_roundtrip_probe.mdk"
)

command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not on PATH — skipping sqlite tandem gate"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) — skipping sqlite tandem gate"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build the native compiler first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$WASM_EMITTER" ] || { echo "build the wasm modules emitter: sh test/wasm/build_wasm_oracle.sh (missing $WASM_EMITTER)"; exit 2; }

# ── Node >= 22 selection (finalized WasmGC encoding — mirror diff_wasm.sh) ─────
NODE=node
major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$major" -lt 22 ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
fi
if [ "$major" -lt 22 ]; then
  echo "sqlite tandem SKIP  Node >= 22 required (have $($NODE --version 2>/dev/null))"
  exit 2
fi

# native `medaka build` is OCaml-free with the native emitter; the wasm build uses
# the native modules-emitter binary (fast, no interpreter) via MEDAKA_WASM_EMITTER.
[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"
export MEDAKA_WASM_EMITTER="$WASM_EMITTER"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
for f in "${CORPUS[@]}"; do
  [ -f "$f" ] || { fail=$((fail+1)); printf 'FAIL %s (missing probe)\n' "$f"; continue; }
  name="$(basename "$f")"

  # 1. native oracle: build + run.
  obin="$WORK/$name.native"
  if ! "$MEDAKA" build --allow-internal "$f" -o "$obin" >"$WORK/nbuild.err" 2>&1; then
    fail=$((fail+1)); printf 'FAIL %s (native build)\n%s\n' "$name" "$(cat "$WORK/nbuild.err")"; continue
  fi
  ref="$("$obin" 2>/dev/null)"

  # 2. wasm: build to a validated .wasm (WAT → wasm-tools parse/validate).
  wasm="$WORK/$name.wasm"
  if ! "$MEDAKA" build --allow-internal --target wasm "$f" -o "$wasm" >"$WORK/wbuild.err" 2>&1; then
    fail=$((fail+1)); printf 'FAIL %s (wasm build)\n%s\n' "$name" "$(cat "$WORK/wbuild.err")"; continue
  fi

  # 3. run under Node, diff stdout.
  got="$("$NODE" "$RUNJS" "$wasm" 2>"$WORK/run.err")"
  if [ "$ref" = "$got" ]; then
    pass=$((pass+1)); printf 'ok   %s (native == wasm)\n' "$name"
  else
    fail=$((fail+1))
    printf 'FAIL %s\n  --- native ---\n%s\n  --- wasm ---\n%s\n  (%s)\n' \
      "$name" "$ref" "$got" "$(cat "$WORK/run.err")"
  fi
done

# ── FILE-backed arm (stage D: writeFileBytes / readFileBytes over Node fs) ─────
for f in "${FILE_CORPUS[@]}"; do
  [ -f "$f" ] || { fail=$((fail+1)); printf 'FAIL %s (missing probe)\n' "$f"; continue; }
  name="$(basename "$f")"

  # 1. native oracle: build + run against a native-only temp .sqlite (arg via argv).
  obin="$WORK/$name.native"
  if ! "$MEDAKA" build --allow-internal "$f" -o "$obin" >"$WORK/nbuild.err" 2>&1; then
    fail=$((fail+1)); printf 'FAIL %s (native build)\n%s\n' "$name" "$(cat "$WORK/nbuild.err")"; continue
  fi
  ref="$("$obin" "$WORK/$name.native.sqlite" 2>/dev/null)"

  # 2. wasm: build to a validated .wasm.
  wasm="$WORK/$name.wasm"
  if ! "$MEDAKA" build --allow-internal --target wasm "$f" -o "$wasm" >"$WORK/wbuild.err" 2>&1; then
    fail=$((fail+1)); printf 'FAIL %s (wasm build)\n%s\n' "$name" "$(cat "$WORK/wbuild.err")"; continue
  fi

  # 3. run under Node with a DISTINCT wasm-only temp .sqlite (arg via MDK_ARGS), diff stdout.
  got="$(MDK_ARGS="$WORK/$name.wasm.sqlite" "$NODE" "$RUNJS" "$wasm" 2>"$WORK/run.err")"
  if [ "$ref" = "$got" ]; then
    pass=$((pass+1)); printf 'ok   %s (file: native == wasm)\n' "$name"
  else
    fail=$((fail+1))
    printf 'FAIL %s (file)\n  --- native ---\n%s\n  --- wasm ---\n%s\n  (%s)\n' \
      "$name" "$ref" "$got" "$(cat "$WORK/run.err")"
  fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
