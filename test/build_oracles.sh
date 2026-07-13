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

# ── Parallel worker mode ───────────────────────────────────────────────────────
# The script re-invokes itself as `sh "$0" --build-one <entry>` under an xargs -P
# pool (see the main loop). Each build is collision-free: the emitter reads shared
# source read-only; the per-entry .ll temp is keyed by the entry's unique basename;
# GC detection here uses `brew --prefix` (no shared temp file). So N builds run
# concurrently with no interference. Worker exits 0 on success, 1 on failure.
if [ "${1:-}" = "--build-one" ]; then
  e="$2"
  src="$ROOT/compiler/entries/$e.mdk"
  out="$BINDIR/$e"
  printf 'building    %s ...\n' "$e"
  if ! ( cd "$ROOT" && MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" MEDAKA_CLANG_OPT="${ORACLE_OPT:--O0}" "$MEDAKA" build --allow-internal "$src" -o "$out" ) >"$BINDIR/$e.buildlog" 2>&1; then
    echo "FAIL: could not native-compile $e:" >&2; tail -8 "$BINDIR/$e.buildlog" >&2; exit 1
  fi
  [ -x "$out" ] || { echo "FAIL: $e build produced no binary" >&2; tail -8 "$BINDIR/$e.buildlog" >&2; exit 1; }
  rm -f "$BINDIR/$e.buildlog"
  exit 0
fi

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
#   eval_autoprint_main   — diff_compiler_engines.sh    (the INTERPRETER arm of the
#                           3-engine differential: `medaka run`'s exact eval path plus
#                           driver/main_autoprint's value-main wrap, so eval honours the
#                           same auto-print contract `medaka build` and wasm_emit do)
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
#   lint_main               — diff_compiler_lint.sh (added by the lint workstream)
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
eval_typed_modules_main eval_modules_main eval_autoprint_main \
core_ir_main core_ir_prelude_main core_ir_typed_main core_ir_roundtrip_main core_ir_modules_main \
llvm_emit_main llvm_emit_typed_main llvm_emit_modules_main \
llvm_bootstrap_lex_main \
lex_main parse_main parse_result_main \
desugar_main desugar_batch mark_main mark_batch \
resolve_main resolve_batch resolve_modules_main \
printer_main positions_main lex_comments_main \
typecheck_main typecheck_golden_batch check_main check_batch \
check_modules_main check_all_main check_match_main exhaust_main lint_main lint_fix_main \
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

# ── newest source mtime across everything an oracle links — any source newer
# than a binary => rebuild it. This MUST cover stdlib/*.mdk and runtime/*.c(.h)
# too: every test/bin/* oracle links stdlib/*.mdk and runtime/medaka_rt.c, so
# scanning only compiler/**.mdk left all 53 oracles silently stale whenever the
# stdlib or C runtime changed (a one-line bug — see AGENTS.md staleness gotcha).
newest_src=0
for f in $(find "$ROOT/compiler" "$ROOT/stdlib" -name '*.mdk'; find "$ROOT/runtime" -name '*.c' -o -name '*.h'); do
  m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
  [ "$m" -gt "$newest_src" ] && newest_src=$m
done

# ── `--for <gate-pattern>...` : build ONLY the oracles those gates actually read ──
#
# Building all 54 oracles is 54 × (medaka build + clang). That is the single most
# expensive thing in the whole test system: measured at ~34s on a 12-core box but
# **18+ minutes on a 2-core CI runner**, where it was 93% of the build job (the
# cold bootstrap from seed, by contrast, is only 80s).
#
# But no gate needs all 54. A gate names its oracle as `test/bin/<name>`, so the
# set is derivable from the gate scripts themselves — no hand-maintained mapping to
# drift. Per-shard need: engines 2, frontend 14, types 10, eval 19, backend 6,
# tools 6. So CI shards build ~19 max, concurrently, instead of 54 serially; and
# `test/preflight.sh` uses the same derivation so an agent touching the parser
# builds 9, not 54.
#
#   sh test/build_oracles.sh --for 'diff_compiler_parse*' 'diff_compiler_fmt'
#
# The derivation is intentionally shared with preflight.sh and the CI matrix: ONE
# source of truth for "which oracle does this gate read".
if [ "${1:-}" = "--for" ]; then
  shift
  [ "$#" -gt 0 ] || { echo "usage: $0 --for '<gate-pattern>' ..."; exit 1; }
  _gates=""
  for _pat in "$@"; do
    for _g in "$ROOT"/test/$_pat.sh; do
      [ -f "$_g" ] || continue
      case " $_gates " in *" $_g "*) ;; *) _gates="$_gates $_g" ;; esac
    done
  done
  [ -n "$_gates" ] || { echo "FAIL: --for matched no gates: $*"; exit 1; }
  _sel=""
  for _g in $_gates; do
    for _o in $(grep -ohE 'test/bin/[a-z_0-9]+' "$_g" 2>/dev/null | sed 's|test/bin/||' | sort -u); do
      # only accept names that are real entries — a gate may mention a path we
      # don't build, and silently "building" a non-entry would be a lie.
      case " $ENTRIES " in
        *" $_o "*) case " $_sel " in *" $_o "*) ;; *) _sel="$_sel $_o" ;; esac ;;
      esac
    done
  done
  [ -n "$_sel" ] || { echo "FAIL: --for selected no oracles from: $*"; exit 1; }
  printf 'building %s of %s oracles (only what these gates read)\n' \
    "$(printf '%s\n' $_sel | grep -vc '^$')" "$(printf '%s\n' $ENTRIES | grep -vc '^$')"
  ENTRIES="$_sel"
fi

# ── Worklist: which entries actually need (re)building ─────────────────────────
# The probe entries are COMPILER internals (compiler/entries/*) whose graphs use
# the internal-only array-kernel externs (arrayGetUnsafe, …); the worker passes
# --allow-internal so the resolve-phase guard trusts them (part of this project).
worklist=""
uptodate=0
for e in $ENTRIES; do
  src="$ROOT/compiler/entries/$e.mdk"
  out="$BINDIR/$e"
  [ -f "$src" ] || { echo "FAIL: missing entry $src"; exit 1; }
  if [ "${FORCE:-0}" != "1" ] && [ -x "$out" ]; then
    bm=$(stat -c %Y "$out" 2>/dev/null || stat -f %m "$out" 2>/dev/null)
    if [ "$bm" -ge "$newest_src" ]; then
      uptodate=$((uptodate+1)); printf 'up-to-date  %s\n' "$e"; continue
    fi
  fi
  worklist="$worklist $e"
done

# ── Parallel build via an xargs -P job pool ────────────────────────────────────
# Default concurrency = logical CPU count (override with JOBS=n). Each build is a
# self-reinvocation (`sh "$0" --build-one <e>`); xargs exits non-zero if any fails.
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
built=0
rc=0
if [ -n "$worklist" ]; then
  built=$(printf '%s\n' $worklist | wc -l | tr -d ' ')
  printf '%s\n' $worklist \
    | xargs -P "$JOBS" -n 1 sh "$0" --build-one \
    || rc=$?
fi
[ "$rc" = 0 ] || { echo "FAIL: one or more oracle builds failed (see FAIL lines above)"; exit 1; }

printf '\noracles ready in %s (%d built, %d up-to-date, JOBS=%s)\n' "$BINDIR" "$built" "$uptodate" "$JOBS"
