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

# ── Per-probe worker (parallel fan-out target) ─────────────────────────────────
# Re-invoked as `bash "$0" --one <mode> <probe>` (mode = mem | file) under an
# xargs -P pool. Each probe builds BOTH the native oracle and the wasm target and
# diffs their stdout. Shared state (MEDAKA/emitters/NODE-abs/RUNJS/dirs) via env;
# per-probe .err + .sqlite temps (no shared scratch) so N run concurrently. Placed
# above the bash-array corpus defs so the worker exits before they are reached.
if [ "${1:-}" = "--one" ]; then
  mode="$2"; f="$3"; name="$(basename "$f")"
  obin="$WORKDIR/$name.native"; wasm="$WORKDIR/$name.wasm"
  st=0; msg=""
  if [ ! -f "$f" ]; then
    msg="FAIL $f (missing probe)"; st=1
  elif ! "$MEDAKA" build --allow-internal "$f" -o "$obin" >"$WORKDIR/$name.nbuild.err" 2>&1; then
    msg="$(printf 'FAIL %s (native build)\n%s' "$name" "$(cat "$WORKDIR/$name.nbuild.err")")"; st=1
  else
    if [ "$mode" = file ]; then ref="$("$obin" "$WORKDIR/$name.native.sqlite" 2>/dev/null)"; else ref="$("$obin" 2>/dev/null)"; fi
    if ! "$MEDAKA" build --allow-internal --target wasm "$f" -o "$wasm" >"$WORKDIR/$name.wbuild.err" 2>&1; then
      msg="$(printf 'FAIL %s (wasm build)\n%s' "$name" "$(cat "$WORKDIR/$name.wbuild.err")")"; st=1
    else
      if [ "$mode" = file ]; then got="$(MDK_ARGS="$WORKDIR/$name.wasm.sqlite" "$NODE" "$RUNJS" "$wasm" 2>"$WORKDIR/$name.run.err")"; else got="$("$NODE" "$RUNJS" "$wasm" 2>"$WORKDIR/$name.run.err")"; fi
      if [ "$ref" = "$got" ]; then msg="ok   $name ($mode: native == wasm)"
      else msg="$(printf 'FAIL %s (%s)\n  --- native ---\n%s\n  --- wasm ---\n%s\n  (%s)' "$name" "$mode" "$ref" "$got" "$(cat "$WORKDIR/$name.run.err")")"; st=1; fi
    fi
  fi
  echo "$st" > "$RESULTDIR/$name.status"
  printf '%s\n' "$msg"
  exit 0
fi

# The in-memory sqlite probe corpus (multi-module — imports lib.*).  Add a probe
# here and it runs on BOTH backends automatically.
CORPUS=(
  "$ROOT/sqlite/inmem_crud_probe.mdk"
  "$ROOT/sqlite/inmem_aggregate_probe.mdk"
  "$ROOT/sqlite/inmem_orderby_probe.mdk"
  "$ROOT/sqlite/inmem_arith_probe.mdk"
  "$ROOT/sqlite/inmem_join_probe.mdk"
  "$ROOT/sqlite/inmem_leftjoin_probe.mdk"
  "$ROOT/sqlite/inmem_distinct_probe.mdk"
  "$ROOT/sqlite/inmem_proj_probe.mdk"
  "$ROOT/sqlite/inmem_groupby_probe.mdk"
  "$ROOT/sqlite/inmem_sqlparse_probe.mdk"
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
RESULTS="$(mktemp -d)"
trap 'rm -rf "$WORK" "$RESULTS"' EXIT

# Fan both corpora (in-memory + file-backed) across an xargs -P pool of --one
# workers (see top of file). Each work item is a tab-separated "<mode>\t<probe>";
# NODE is resolved to its absolute path once (post nvm selection). Each probe does
# two `medaka build`s (native + wasm target), so parallelism matters.
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
NODE_ABS="$(command -v "$NODE" 2>/dev/null || echo "$NODE")"
{
  for f in "${CORPUS[@]}"; do printf 'mem\t%s\n' "$f"; done
  for f in "${FILE_CORPUS[@]}"; do printf 'file\t%s\n' "$f"; done
} > "$WORK/worklist.tsv"

MEDAKA="$MEDAKA" MEDAKA_EMITTER="${MEDAKA_EMITTER:-$EMITTER}" MEDAKA_WASM_EMITTER="$WASM_EMITTER" \
NODE="$NODE_ABS" RUNJS="$RUNJS" WORKDIR="$WORK" RESULTDIR="$RESULTS" \
  xargs -P "$JOBS" -n 2 bash "$0" --one < "$WORK/worklist.tsv"

pass=0; fail=0
for s in "$RESULTS"/*.status; do
  [ -f "$s" ] || continue
  if [ "$(cat "$s")" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
