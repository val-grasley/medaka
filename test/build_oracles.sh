#!/bin/sh
# build_oracles.sh — compile the selfhost STAGE ENTRIES the OCaml-free gates need
# into native binaries under test/bin/<entry>, via the native `./medaka build`.
#
# This is the category-C re-root build step (REROOT-PLAN.md §3b / Phase 2): each
# gate that used to host a selfhost entry on the OCaml interpreter
# (`main.exe run selfhost/entries/<entry>.mdk …`) instead runs the pre-compiled
# native binary `test/bin/<entry>` with the SAME positional args. Building these
# binaries is the whole OCaml-removal lever for those gates — no OCaml at gate time.
#
# Design:
#   * Idempotent: a binary is rebuilt only if it is older than ANY selfhost/**.mdk
#     (or absent). FORCE=1 rebuilds unconditionally.
#   * Bootstraps ./medaka + ./medaka_emitter (warm `make medaka`) if absent — both
#     are OCaml-free (cold path bootstraps from the gz seed).
#   * Opt-in: skips cleanly (exit 2) when clang/libgc are absent, mirroring the
#     other native scripts (build_native_medaka.sh / diff_native_cli.sh).
#
# ENTRIES table below lists every entry a re-rooted gate consumes. Add a row when
# a new gate is re-rooted onto a native oracle.
#
# Usage:   sh test/build_oracles.sh          # build stale/missing oracles
#          FORCE=1 sh test/build_oracles.sh   # rebuild all
# Exit:    0 built/up-to-date; 2 opt-in skip (no clang/libgc); 1 on a build error.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINDIR="$ROOT/test/bin"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
CC="${CC:-clang}"

# ── Entries the step-1 OCaml-free gates need (one per line; no extension) ──────
#   eval_run_main     — diff_selfhost_eval_run.sh        (=== EVAL === goldens)
#   eval_run_batch    — diff_selfhost_eval_run_batch.sh  (=== EVAL === goldens)
#   core_ir_run_main  — diff_selfhost_core_ir_run.sh     (=== EVAL === goldens)
#   core_ir_dump_main — diff_selfhost_core_ir_sexp.sh    (.sexp snapshot goldens)
#   ── Phase 2 §2a value gates (eval / core-ir / llvm), goldens = .eval.golden ──
#   eval_main             — diff_selfhost_eval.sh
#   eval_prelude_main     — diff_selfhost_eval_prelude.sh + diff_selfhost_eval_list.sh
#   eval_prelude_batch    — diff_selfhost_eval_prelude_batch.sh
#   eval_list_batch       — diff_selfhost_eval_list_batch.sh
#   eval_dict_main        — diff_selfhost_eval_dict.sh
#   eval_dict_batch       — diff_selfhost_eval_dict_batch.sh
#   eval_typed_main       — diff_selfhost_eval_typed.sh
#   eval_typed_batch      — diff_selfhost_eval_typed_batch.sh
#   eval_typed_modules_main — diff_selfhost_eval_typed_modules.sh
#   eval_modules_main     — diff_selfhost_eval_modules.sh
#   core_ir_main          — diff_selfhost_core_ir.sh
#   core_ir_prelude_main  — diff_selfhost_core_ir_prelude.sh + diff_selfhost_core_ir_list.sh
#   core_ir_typed_main    — diff_selfhost_core_ir_typed.sh
#   core_ir_roundtrip_main — diff_selfhost_core_ir_roundtrip.sh
#   core_ir_modules_main  — diff_selfhost_core_ir_modules.sh
#   llvm_emit_main        — diff_selfhost_llvm.sh        (emit → clang → run vs golden)
#   llvm_emit_typed_main  — diff_selfhost_llvm_typed.sh
#   llvm_emit_modules_main — diff_selfhost_llvm_modules.sh
ENTRIES="eval_run_main eval_run_batch core_ir_run_main core_ir_dump_main \
eval_main eval_prelude_main eval_prelude_batch eval_list_batch \
eval_dict_main eval_dict_batch eval_typed_main eval_typed_batch \
eval_typed_modules_main eval_modules_main \
core_ir_main core_ir_prelude_main core_ir_typed_main core_ir_roundtrip_main core_ir_modules_main \
llvm_emit_main llvm_emit_typed_main llvm_emit_modules_main"

# ── Opt-in skip when clang/libgc absent (mirror the other native scripts) ──────
command -v "$CC" >/dev/null 2>&1 || {
  echo "no C compiler ($CC) on PATH — skipping (opt-in)"; exit 2; }
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then
  :
elif [ -n "${GC_PREFIX:-}" ] && [ -d "${GC_PREFIX}" ]; then
  :
elif [ -d /opt/homebrew/include/gc ] || [ -d /usr/local/include/gc ] || [ -d /usr/include/gc ]; then
  :
else
  echo "libgc (bdw-gc) not found — skipping (opt-in; install bdw-gc or set GC_PREFIX)"; exit 2
fi

mkdir -p "$BINDIR"

# ── Ensure the native compiler exists (OCaml-free; warm make path) ─────────────
if [ ! -x "$MEDAKA" ] || [ ! -x "$EMITTER" ]; then
  echo "native medaka/emitter absent — bootstrapping via 'make medaka' (OCaml-free) ..."
  ( cd "$ROOT" && make medaka ) || { echo "FAIL: could not build ./medaka"; exit 1; }
fi
[ -x "$MEDAKA" ] && [ -x "$EMITTER" ] || { echo "FAIL: ./medaka or ./medaka_emitter still missing"; exit 1; }

# ── newest selfhost/*.mdk mtime — any source newer than a binary => rebuild it ─
newest_src=0
for f in $(find "$ROOT/selfhost" -name '*.mdk'); do
  m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
  [ "$m" -gt "$newest_src" ] && newest_src=$m
done

built=0; uptodate=0
for e in $ENTRIES; do
  src="$ROOT/selfhost/entries/$e.mdk"
  out="$BINDIR/$e"
  [ -f "$src" ] || { echo "FAIL: missing entry $src"; exit 1; }
  if [ "${FORCE:-0}" != "1" ] && [ -x "$out" ]; then
    bm=$(stat -f %m "$out" 2>/dev/null || stat -c %Y "$out" 2>/dev/null)
    if [ "$bm" -ge "$newest_src" ]; then
      uptodate=$((uptodate+1)); printf 'up-to-date  %s\n' "$e"; continue
    fi
  fi
  printf 'building    %s ...\n' "$e"
  if ! ( cd "$ROOT" && MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" build "$src" -o "$out" ) >"$BINDIR/$e.buildlog" 2>&1; then
    echo "FAIL: could not native-compile $e:"; tail -8 "$BINDIR/$e.buildlog"; exit 1
  fi
  [ -x "$out" ] || { echo "FAIL: $e build produced no binary"; tail -8 "$BINDIR/$e.buildlog"; exit 1; }
  rm -f "$BINDIR/$e.buildlog"
  built=$((built+1))
done

printf '\noracles ready in %s (%d built, %d up-to-date)\n' "$BINDIR" "$built" "$uptodate"
