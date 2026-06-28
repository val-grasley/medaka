#!/bin/sh
# build_oracles.sh — compile the compiler STAGE ENTRIES the OCaml-free gates need
# into native binaries under test/bin/<entry>, via the native `./medaka build`.
#
# This is the category-C re-root build step (REROOT-PLAN.md §3b / Phase 2): each
# gate that used to host a compiler entry on the OCaml interpreter
# (`main.exe run compiler/entries/<entry>.mdk …`) instead runs the pre-compiled
# native binary `test/bin/<entry>` with the SAME positional args. Building these
# binaries is the whole OCaml-removal lever for those gates — no OCaml at gate time.
#
# Design:
#   * Idempotent: a binary is rebuilt only if it is older than ANY compiler/**.mdk
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
#   eval_run_main     — diff_compiler_eval_run.sh        (=== EVAL === goldens)
#   eval_run_batch    — diff_compiler_eval_run_batch.sh  (=== EVAL === goldens)
#   core_ir_run_main  — diff_compiler_core_ir_run.sh     (=== EVAL === goldens)
#   core_ir_dump_main — diff_compiler_core_ir_sexp.sh    (.sexp snapshot goldens)
#   ── Phase 2 §2a value gates (eval / core-ir / llvm), goldens = .eval.golden ──
#   eval_main             — diff_compiler_eval.sh
#   eval_prelude_main     — diff_compiler_eval_prelude.sh + diff_compiler_eval_list.sh
#   eval_prelude_batch    — diff_compiler_eval_prelude_batch.sh
#   eval_list_batch       — diff_compiler_eval_list_batch.sh
#   eval_dict_main        — diff_compiler_eval_dict.sh
#   eval_dict_batch       — diff_compiler_eval_dict_batch.sh
#   eval_typed_main       — diff_compiler_eval_typed.sh
#   eval_typed_batch      — diff_compiler_eval_typed_batch.sh
#   eval_typed_modules_main — diff_compiler_eval_typed_modules.sh
#   eval_modules_main     — diff_compiler_eval_modules.sh
#   core_ir_main          — diff_compiler_core_ir.sh
#   core_ir_prelude_main  — diff_compiler_core_ir_prelude.sh + diff_compiler_core_ir_list.sh
#   core_ir_typed_main    — diff_compiler_core_ir_typed.sh
#   core_ir_roundtrip_main — diff_compiler_core_ir_roundtrip.sh
#   core_ir_modules_main  — diff_compiler_core_ir_modules.sh
#   llvm_emit_main        — diff_compiler_llvm.sh        (emit → clang → run vs golden)
#   llvm_emit_typed_main  — diff_compiler_llvm_typed.sh
#   llvm_emit_modules_main — diff_compiler_llvm_modules.sh
#   ── Phase 2 §2b front-end gates, goldens captured from dev probes ──
#   lex_main              — diff_compiler_lexer.sh / diff_compiler_lex_files.sh
#   parse_main            — diff_compiler_parse.sh
#   parse_result_main     — diff_compiler_parse_result.sh
#   desugar_main          — diff_compiler_desugar.sh
#   desugar_batch         — diff_compiler_desugar_batch.sh
#   mark_main             — diff_compiler_mark.sh
#   mark_batch            — diff_compiler_mark_batch.sh
#   resolve_main          — diff_compiler_resolve.sh
#   resolve_batch         — diff_compiler_resolve_batch.sh
#   resolve_modules_main  — diff_compiler_resolve_modules.sh
#   printer_main          — diff_compiler_printer.sh
#   positions_main        — diff_compiler_positions.sh
#   lex_comments_main     — diff_compiler_comments.sh
#   ── Phase 2 §2b typecheck/check/error gates ──
#   typecheck_main          — diff_compiler_typecheck.sh / _errors / _panic_errors / _golden
#   typecheck_golden_batch  — diff_compiler_typecheck_golden_batch.sh
#   check_main              — diff_compiler_typecheck_errors.sh (driver B) / diff_compiler_check.sh
#   check_batch             — diff_compiler_check_batch.sh
#   check_modules_main      — diff_compiler_check_modules.sh
#   check_all_main          — diff_compiler_check_modules_batch.sh
#   check_match_main        — diff_compiler_check_match.sh
#   exhaust_main            — diff_compiler_exhaust.sh
#   diagnostics_main        — diff_compiler_diagnostics.sh
#   diagnostics_project_main — diff_compiler_analyze_project.sh
#   ── Phase 2 §2c tooling gates (fmt/new/test/repl/lsp) ──
#   fmt_main    — diff_compiler_fmt.sh        (native host vs .fmt.golden)
#   new_main    — diff_compiler_new.sh        (native scaffold tree vs golden tree)
#   test_main   — diff_compiler_test.sh       (native test report vs .test.golden)
#   repl_main   — diff_compiler_repl.sh       (SKIPPED re-root; see capture_goldens.sh)
#   (lsp_main is NOT a build target: `medaka build lsp_main.mdk` fails the native G1
#    typecheck gate — tools.lsp imports don't resolve under the build path's roots.
#    The 3 lsp gates stay on the OCaml oracle.  See REROOT-PLAN STOP guardrail.)
ENTRIES="eval_run_main eval_run_batch core_ir_run_main core_ir_dump_main \
eval_main eval_prelude_main eval_prelude_batch eval_list_batch \
eval_dict_main eval_dict_batch eval_typed_main eval_typed_batch \
eval_typed_modules_main eval_modules_main \
core_ir_main core_ir_prelude_main core_ir_typed_main core_ir_roundtrip_main core_ir_modules_main \
llvm_emit_main llvm_emit_typed_main llvm_emit_modules_main \
llvm_bootstrap_lex_main \
lex_main parse_main parse_result_main \
desugar_main desugar_batch mark_main mark_batch \
resolve_main resolve_batch resolve_modules_main \
printer_main positions_main lex_comments_main \
typecheck_main typecheck_golden_batch check_main check_batch \
check_modules_main check_all_main check_match_main exhaust_main \
diagnostics_main diagnostics_project_main \
fmt_main new_main test_main repl_main fuzz_gen_main"

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

# ── newest compiler/*.mdk mtime — any source newer than a binary => rebuild it ─
newest_src=0
for f in $(find "$ROOT/compiler" -name '*.mdk'); do
  m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
  [ "$m" -gt "$newest_src" ] && newest_src=$m
done

built=0; uptodate=0
for e in $ENTRIES; do
  src="$ROOT/compiler/entries/$e.mdk"
  out="$BINDIR/$e"
  [ -f "$src" ] || { echo "FAIL: missing entry $src"; exit 1; }
  if [ "${FORCE:-0}" != "1" ] && [ -x "$out" ]; then
    bm=$(stat -f %m "$out" 2>/dev/null || stat -c %Y "$out" 2>/dev/null)
    if [ "$bm" -ge "$newest_src" ]; then
      uptodate=$((uptodate+1)); printf 'up-to-date  %s\n' "$e"; continue
    fi
  fi
  printf 'building    %s ...\n' "$e"
  # The probe entries are COMPILER internals (compiler/entries/*) whose graphs use
  # the internal-only array-kernel externs (arrayGetUnsafe, …); pass --allow-internal
  # so the resolve-phase guard trusts them (they are part of this project).
  if ! ( cd "$ROOT" && MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" build --allow-internal "$src" -o "$out" ) >"$BINDIR/$e.buildlog" 2>&1; then
    echo "FAIL: could not native-compile $e:"; tail -8 "$BINDIR/$e.buildlog"; exit 1
  fi
  [ -x "$out" ] || { echo "FAIL: $e build produced no binary"; tail -8 "$BINDIR/$e.buildlog"; exit 1; }
  rm -f "$BINDIR/$e.buildlog"
  built=$((built+1))
done

printf '\noracles ready in %s (%d built, %d up-to-date)\n' "$BINDIR" "$built" "$uptodate"
